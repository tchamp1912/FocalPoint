//! Durable local schedules. Claims are committed before the caller launches a
//! process; a restart never replays an already claimed occurrence.
use serde::{Deserialize, Serialize};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

const MAX_JOBS: usize = 100;
const MAX_HISTORY: usize = 20;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ScheduleLaunch {
    pub provider: String,
    pub agent_type: String,
    pub model: String,
    pub cwd: String,
    pub task: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_launcher: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_mode: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScheduleSpec {
    pub id: String,
    pub name: String,
    pub cron: String,
    pub timezone: String,
    pub enabled: bool,
    pub launch: ScheduleLaunch,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScheduleRun {
    pub scheduled_at: u64,
    pub attempted_at: u64,
    pub finished_at: Option<u64>,
    pub task_id: String,
    /// `launching`, `launched`, `error`, `skipped`, or `interrupted`. A pending
    /// claim becomes interrupted after restart and is deliberately not retried.
    pub status: String,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScheduledJob {
    #[serde(flatten)]
    pub spec: ScheduleSpec,
    pub next_run_at: u64,
    pub active_task_id: Option<String>,
    #[serde(default)]
    pub last_runs: Vec<ScheduleRun>,
}

#[derive(Clone, Debug)]
pub struct ScheduleClaim {
    /// Full immutable claim snapshot; callers compare this before opening a
    /// terminal so edits to timing or launch content cancel stale claims.
    pub spec: ScheduleSpec,
    pub id: String,
    pub task_id: String,
    pub launch: ScheduleLaunch,
}

#[derive(Serialize, Deserialize)]
struct DiskStore {
    version: u32,
    jobs: Vec<ScheduledJob>,
}

pub struct ScheduleStore {
    _lock: fs::File,
    path: PathBuf,
    jobs: Vec<ScheduledJob>,
}

impl ScheduleStore {
    pub fn load(path: impl Into<PathBuf>) -> Result<Self, String> {
        let path = path.into();
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or("Schedules path needs a parent directory")?;
        if !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
                .map_err(|e| e.to_string())?;
        }
        let lock_path = path.with_extension("lock");
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(lock_path)
            .map_err(|e| format!("Cannot open schedules lock: {e}"))?;
        if !lock.metadata().map_err(|e| e.to_string())?.is_file() {
            return Err("Invalid schedules lock file".into());
        }
        lock.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Schedules are already owned by another daemon".into());
        }
        let mut recovered = false;
        let jobs = match fs::metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(format!("Cannot read schedules: {e}")),
            Ok(meta) => {
                if !meta.is_file() || meta.len() > 32 * 1024 * 1024 {
                    return Err("Schedules file is invalid or exceeds 32 MiB".into());
                }
                let mut disk: DiskStore =
                    serde_json::from_slice(&fs::read(&path).map_err(|e| e.to_string())?)
                        .map_err(|e| format!("Cannot decode schedules: {e}"))?;
                if disk.version != 1 || disk.jobs.len() > MAX_JOBS {
                    return Err("Unsupported schedules version or too many schedules".into());
                }
                let mut ids = std::collections::HashSet::new();
                for job in &mut disk.jobs {
                    // Missing folders/scripts are runtime failures, not grounds
                    // for discarding every saved schedule on startup.
                    validate_structure(&job.spec)?;
                    for run in &mut job.last_runs {
                        if run.status == "launching" {
                            run.status = "interrupted".into();
                            run.error = Some("Daemon restarted before launch outcome was recorded; occurrence will not be replayed".into());
                            recovered = true;
                        }
                    }
                    if !ids.insert(job.spec.id.clone()) || job.last_runs.len() > MAX_HISTORY {
                        return Err("Invalid duplicate schedule or oversized last_runs".into());
                    }
                }
                disk.jobs
            }
        };
        let mut store = Self {
            _lock: lock,
            path,
            jobs,
        };
        if recovered {
            store.commit(store.jobs.clone())?;
        }
        Ok(store)
    }

    pub fn jobs(&self) -> &[ScheduledJob] {
        &self.jobs
    }

    pub fn upsert(&mut self, spec: ScheduleSpec, now: u64) -> Result<ScheduledJob, String> {
        if let Some(existing) = self.jobs.iter().find(|job| job.spec == spec) {
            return Ok(existing.clone());
        }
        validate_spec(&spec)?;
        let next_run_at = next_run_after(&spec.cron, &spec.timezone, now)?;
        let mut jobs = self.jobs.clone();
        let job = if let Some(existing) = jobs.iter_mut().find(|j| j.spec.id == spec.id) {
            existing.spec = spec;
            existing.next_run_at = next_run_at;
            existing.clone()
        } else {
            if jobs.len() >= MAX_JOBS {
                return Err("At most 100 schedules may be saved".into());
            }
            let job = ScheduledJob {
                spec,
                next_run_at,
                active_task_id: None,
                last_runs: Vec::new(),
            };
            jobs.push(job.clone());
            job
        };
        self.commit(jobs)?;
        Ok(job)
    }

    pub fn set_enabled(
        &mut self,
        id: &str,
        enabled: bool,
        now: u64,
    ) -> Result<ScheduledJob, String> {
        let mut jobs = self.jobs.clone();
        let job = jobs
            .iter_mut()
            .find(|j| j.spec.id == id)
            .ok_or("Schedule not found")?;
        if job.spec.enabled == enabled {
            return Ok(job.clone());
        }
        job.spec.enabled = enabled;
        if enabled {
            job.next_run_at = next_run_after(&job.spec.cron, &job.spec.timezone, now)?;
        }
        let result = job.clone();
        self.commit(jobs)?;
        Ok(result)
    }

    pub fn delete(&mut self, id: &str) -> Result<(), String> {
        let mut jobs = self.jobs.clone();
        let before = jobs.len();
        jobs.retain(|j| j.spec.id != id);
        if before == jobs.len() {
            return Err("Schedule not found".into());
        }
        self.commit(jobs)
    }

    /// Coalesce missed occurrences into one claim. `is_active` must include
    /// pending launch reservations as well as running/waiting managed tasks.
    pub fn claim_due(
        &mut self,
        now: u64,
        mut is_active: impl FnMut(&str) -> bool,
    ) -> Result<Vec<ScheduleClaim>, String> {
        let mut jobs = self.jobs.clone();
        let mut claims = Vec::new();
        let mut changed = false;
        for job in &mut jobs {
            if !job.spec.enabled || job.next_run_at > now {
                continue;
            }
            changed = true;
            let scheduled_at = job.next_run_at;
            job.next_run_at = next_run_after(&job.spec.cron, &job.spec.timezone, now)?;
            let task_id = format!("schedule-{}-{scheduled_at}", job.spec.id);
            let blocked = job.active_task_id.as_deref().is_some_and(&mut is_active);
            let run = ScheduleRun {
                scheduled_at,
                attempted_at: now,
                finished_at: if blocked { Some(now) } else { None },
                task_id: task_id.clone(),
                status: if blocked { "skipped" } else { "launching" }.into(),
                error: if blocked {
                    Some("Previous scheduled session is still active".into())
                } else {
                    None
                },
            };
            job.last_runs.insert(0, run);
            if job.last_runs.len() > MAX_HISTORY {
                job.last_runs.pop();
            }
            if !blocked {
                job.active_task_id = Some(task_id.clone());
                claims.push(ScheduleClaim {
                    spec: job.spec.clone(),
                    id: job.spec.id.clone(),
                    task_id,
                    launch: job.spec.launch.clone(),
                });
            }
        }
        if changed {
            self.commit(jobs)?;
        }
        Ok(claims)
    }

    /// Record launch acceptance/failure, not the eventual agent task result.
    pub fn finish(
        &mut self,
        id: &str,
        task_id: &str,
        now: u64,
        error: Option<String>,
    ) -> Result<(), String> {
        let mut jobs = self.jobs.clone();
        let job = jobs
            .iter_mut()
            .find(|j| j.spec.id == id)
            .ok_or("Schedule not found")?;
        let run = job
            .last_runs
            .iter_mut()
            .find(|r| r.task_id == task_id && r.status == "launching")
            .ok_or("Pending schedule run not found")?;
        run.finished_at = Some(now);
        run.status = if error.is_some() { "error" } else { "launched" }.into();
        run.error = error.map(|s| s.chars().take(2048).collect());
        // Even a failed open can leave a live terminal or reservation. Retain
        // its identity so the next tick asks the daemon before overlapping it.
        self.commit(jobs)
    }

    fn commit(&mut self, jobs: Vec<ScheduledJob>) -> Result<(), String> {
        let data = serde_json::to_vec_pretty(&DiskStore {
            version: 1,
            jobs: jobs.clone(),
        })
        .map_err(|e| e.to_string())?;
        let parent = self
            .path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or("Schedules path needs a parent directory")?;
        if !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
                .map_err(|e| e.to_string())?;
        }
        let temp = parent.join(format!(
            ".schedules-{}-{}.tmp",
            std::process::id(),
            TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let result = (|| -> std::io::Result<()> {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp)?;
            file.write_all(&data)?;
            file.sync_all()?;
            fs::rename(&temp, &self.path)?;
            // The rename is the commit point. A directory fsync is best effort
            // on filesystems that do not support it; never report a rollback
            // after the file has already changed.
            let _ = fs::File::open(parent).and_then(|directory| directory.sync_all());
            Ok(())
        })();
        if let Err(error) = result {
            let _ = fs::remove_file(&temp);
            return Err(format!("Cannot save schedules: {error}"));
        }
        self.jobs = jobs;
        Ok(())
    }
}

fn bounded(value: &str, max: usize, field: &str, multiline: bool) -> Result<(), String> {
    if value.trim().is_empty()
        || value.len() > max
        || value
            .chars()
            .any(|c| c == '\0' || (!multiline && c.is_control()))
    {
        Err(format!(
            "{field} must contain 1-{max} bytes{}",
            if multiline { "" } else { " of printable text" }
        ))
    } else {
        Ok(())
    }
}

fn validate_structure(spec: &ScheduleSpec) -> Result<(), String> {
    if spec.id.is_empty()
        || spec.id.len() > 32
        || !spec
            .id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return Err(
            "Schedule id must use 1-32 letters, digits, dots, underscores, or dashes".into(),
        );
    }
    bounded(&spec.name, 256, "name", false)?;
    Cron::parse(&spec.cron)?;
    if !matches!(spec.timezone.as_str(), "local" | "UTC") {
        return Err("timezone must be local or UTC".into());
    }
    let launch = &spec.launch;
    if !matches!(
        launch.provider.as_str(),
        "claude" | "codex" | "gemini" | "cursor"
    ) {
        return Err("Unsupported scheduled provider".into());
    }
    bounded(&launch.agent_type, 128, "agent_type", false)?;
    bounded(&launch.model, 128, "model", false)?;
    if !launch
        .agent_type
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        || matches!(
            launch.agent_type.to_ascii_lowercase().as_str(),
            "auto" | "default" | "general"
        )
    {
        return Err("agent_type must be a concrete agent id or direct".into());
    }
    if !launch
        .model
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b"._-/:@".contains(&b))
        || matches!(
            launch.model.to_ascii_lowercase().as_str(),
            "auto" | "default" | "provider-default"
        )
    {
        return Err("model must be a concrete model id".into());
    }
    bounded(&launch.cwd, 4096, "cwd", false)?;
    bounded(&launch.task, 16_384, "task", true)?;
    bounded(&launch.title, 256, "title", false)?;
    if let Some(path) = &launch.custom_launcher {
        bounded(path, 4096, "custom_launcher", false)?;
        if launch.provider != "claude" {
            return Err("custom_launcher is only supported for Claude".into());
        }
    }
    if let Some(color) = &launch.terminal_color {
        if color.len() != 7
            || !color.starts_with('#')
            || !color[1..].bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err("terminal_color must be #RRGGBB".into());
        }
    }
    if let Some(mode) = &launch.cursor_mode {
        if launch.provider != "cursor" || !matches!(mode.as_str(), "headless" | "attachable") {
            return Err("cursor_mode requires Cursor and headless or attachable".into());
        }
    }
    Ok(())
}

pub fn validate_spec(spec: &ScheduleSpec) -> Result<(), String> {
    validate_structure(spec)?;
    let cwd = Path::new(&spec.launch.cwd);
    if !cwd.is_absolute() || !cwd.is_dir() {
        return Err("cwd must be an existing absolute directory".into());
    }
    if let Some(launcher) = &spec.launch.custom_launcher {
        let path = Path::new(launcher);
        if !path.is_absolute()
            || !path.is_file()
            || fs::metadata(path)
                .map_err(|e| e.to_string())?
                .permissions()
                .mode()
                & 0o111
                == 0
        {
            return Err("custom_launcher must be an existing absolute executable file".into());
        }
    }
    Ok(())
}

#[derive(Debug)]
struct Field {
    values: Vec<bool>,
    wildcard: bool,
}
impl Field {
    fn parse(input: &str, min: usize, max: usize) -> Result<Self, String> {
        let mut field = Self {
            values: vec![false; max + 1],
            wildcard: input.starts_with('*'),
        };
        let number = |s: &str| -> Result<usize, String> {
            if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                return Err("Cron fields must be numeric".into());
            }
            let n = s.parse::<usize>().map_err(|_| "Cron number is too large")?;
            if n < min || n > max {
                return Err(format!("Cron value must be between {min} and {max}"));
            }
            Ok(n)
        };
        for item in input.split(',') {
            let parts: Vec<_> = item.split('/').collect();
            if parts.len() > 2 {
                return Err("Invalid cron step".into());
            }
            let step = if parts.len() == 2 {
                let s = parts[1];
                if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                    return Err("Invalid cron step".into());
                }
                let n = s.parse::<usize>().map_err(|_| "Invalid cron step")?;
                if n == 0 || n > max + 1 {
                    return Err("Cron step is out of range".into());
                }
                n
            } else {
                1
            };
            let (start, end) = if parts[0] == "*" {
                (min, max)
            } else if let Some((a, b)) = parts[0].split_once('-') {
                (number(a)?, number(b)?)
            } else {
                let n = number(parts[0])?;
                (n, if parts.len() == 2 { max } else { n })
            };
            if start > end {
                return Err("Cron ranges must ascend".into());
            }
            for n in (start..=end).step_by(step) {
                field.values[n] = true;
            }
        }
        Ok(field)
    }
    fn contains(&self, n: usize) -> bool {
        self.values.get(n).copied().unwrap_or(false)
    }
}

#[derive(Debug)]
pub struct Cron {
    minute: Field,
    hour: Field,
    day: Field,
    month: Field,
    weekday: Field,
}
impl Cron {
    pub fn parse(expression: &str) -> Result<Self, String> {
        if expression.len() > 128 {
            return Err("Cron expression exceeds 128 bytes".into());
        }
        let fields: Vec<_> = expression.split_whitespace().collect();
        if fields.len() != 5 {
            return Err("Cron needs five fields: minute hour day month weekday".into());
        }
        Ok(Self {
            minute: Field::parse(fields[0], 0, 59)?,
            hour: Field::parse(fields[1], 0, 23)?,
            day: Field::parse(fields[2], 1, 31)?,
            month: Field::parse(fields[3], 1, 12)?,
            weekday: Field::parse(fields[4], 0, 7)?,
        })
    }

    pub fn next_after(&self, timezone: &str, now: u64) -> Result<u64, String> {
        if !matches!(timezone, "UTC" | "local") {
            return Err("timezone must be local or UTC".into());
        }
        let mut candidate = now
            .checked_div(60)
            .and_then(|v| v.checked_add(1))
            .and_then(|v| v.checked_mul(60))
            .ok_or("Schedule time overflow")?;
        // Eight years includes the longest possible leap-day gap across a
        // non-leap century (2096 -> 2104); impossible dates fail explicitly.
        let limit = candidate
            .checked_add(366 * 24 * 60 * 60 * 8)
            .ok_or("Schedule time overflow")?;
        while candidate <= limit {
            let raw: libc::time_t = candidate
                .try_into()
                .map_err(|_| "Schedule time is out of range")?;
            let mut parts: libc::tm = unsafe { std::mem::zeroed() };
            let result = unsafe {
                if timezone == "UTC" {
                    libc::gmtime_r(&raw, &mut parts)
                } else {
                    libc::localtime_r(&raw, &mut parts)
                }
            };
            if result.is_null() {
                return Err("Cannot resolve schedule calendar time".into());
            }
            let dom = self.day.contains(parts.tm_mday as usize);
            let dow = self.weekday.contains(parts.tm_wday as usize)
                || (parts.tm_wday == 0 && self.weekday.contains(7));
            let day_matches = if self.day.wildcard || self.weekday.wildcard {
                dom && dow
            } else {
                dom || dow
            };
            let date_matches = self.month.contains(parts.tm_mon as usize + 1) && day_matches;
            if date_matches
                && self.hour.contains(parts.tm_hour as usize)
                && self.minute.contains(parts.tm_min as usize)
            {
                return Ok(candidate);
            }
            // Skip to the next hour only when the date/hour cannot match.
            // UTC stepping retains both sides of local DST transitions.
            let minutes = if !date_matches || !self.hour.contains(parts.tm_hour as usize) {
                (60 - parts.tm_min) as u64
            } else {
                1
            };
            candidate = candidate
                .checked_add(minutes * 60)
                .ok_or("Schedule time overflow")?;
        }
        Err("Cron has no occurrence in the next eight years; check day and month".into())
    }
}

pub fn next_run_after(cron: &str, timezone: &str, now: u64) -> Result<u64, String> {
    Cron::parse(cron)?.next_after(timezone, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "focalpoint-schedule-test-{}-{}",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn spec(&self) -> ScheduleSpec {
            ScheduleSpec {
                id: "daily-review".into(),
                name: "Review".into(),
                cron: "* * * * *".into(),
                timezone: "UTC".into(),
                enabled: true,
                launch: ScheduleLaunch {
                    provider: "claude".into(),
                    agent_type: "direct".into(),
                    model: "sonnet".into(),
                    cwd: self.0.to_string_lossy().into(),
                    task: "Review yesterday's changes.\nReport findings.".into(),
                    title: "Daily review".into(),
                    custom_launcher: None,
                    terminal_color: None,
                    cursor_mode: None,
                },
            }
        }
        fn store(&self) -> ScheduleStore {
            ScheduleStore::load(self.0.join("schedules.json")).unwrap()
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn utc(year: i32, month: i32, day: i32, hour: i32, minute: i32) -> u64 {
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        tm.tm_year = year - 1900;
        tm.tm_mon = month - 1;
        tm.tm_mday = day;
        tm.tm_hour = hour;
        tm.tm_min = minute;
        unsafe { libc::timegm(&mut tm) as u64 }
    }
    #[test]
    fn numeric_cron_lists_ranges_steps_and_sunday_alias() {
        let now = utc(2026, 9, 14, 9, 0); // Monday
        assert_eq!(
            next_run_after("5,10-20/5 9-17 * * 1-5", "UTC", now).unwrap(),
            now + 300
        );
        assert_eq!(
            next_run_after("*/15 * * * *", "UTC", now).unwrap(),
            now + 900
        );
        assert_eq!(
            next_run_after("0 0 * * 7", "UTC", now).unwrap(),
            utc(2026, 9, 20, 0, 0)
        );
        assert_eq!(
            next_run_after("0 0 * * 0", "UTC", now).unwrap(),
            utc(2026, 9, 20, 0, 0)
        );
        assert!(next_run_after("* * * * *", "local", now).unwrap() > now);
    }
    #[test]
    fn invalid_cron_rejected_without_panics() {
        for expression in [
            "",
            "* * * *",
            "* * * * * *",
            "60 * * * *",
            "* 24 * * *",
            "* * 0 * *",
            "* * * 13 *",
            "* * * * 8",
            "*/0 * * * *",
            "0-2/0 * * * *",
            "1-0 * * * *",
            "1,,2 * * * *",
            "a * * * *",
            "1/2/3 * * * *",
            "1-2-3 * * * *",
            "+1 * * * *",
        ] {
            assert!(Cron::parse(expression).is_err(), "accepted {expression}");
        }
        assert!(next_run_after("* * * * *", "America/New_York", 0).is_err());
        assert!(next_run_after("* * * * *", "UTC", u64::MAX).is_err());
        assert!(next_run_after("0 0 31 2 *", "UTC", utc(2026, 1, 1, 0, 0)).is_err());
    }
    #[test]
    fn leap_days_and_standard_day_field_matching() {
        assert_eq!(
            next_run_after("0 0 29 2 *", "UTC", utc(2025, 1, 1, 0, 0)).unwrap(),
            utc(2028, 2, 29, 0, 0)
        );
        assert_eq!(
            next_run_after("0 0 29 2 *", "UTC", utc(2096, 3, 1, 0, 0)).unwrap(),
            utc(2104, 2, 29, 0, 0)
        );
        // Restricted DOM and DOW use OR, so Monday matches before the 20th.
        assert_eq!(
            next_run_after("0 0 20 * 1", "UTC", utc(2026, 9, 13, 0, 0)).unwrap(),
            utc(2026, 9, 14, 0, 0)
        );
        // Wildcard DOM requires the weekday restriction.
        assert_eq!(
            next_run_after("0 0 * * 1", "UTC", utc(2026, 9, 14, 0, 0)).unwrap(),
            utc(2026, 9, 21, 0, 0)
        );
    }
    #[test]
    fn durable_claim_coalesces_missed_ticks_and_never_replays_after_restart() {
        let temp = Temp::new();
        let mut store = temp.store();
        store.upsert(temp.spec(), 0).unwrap();
        let claims = store.claim_due(3601, |_| false).unwrap();
        assert_eq!(claims.len(), 1);
        assert_eq!(claims[0].task_id, "schedule-daily-review-60");
        assert_eq!(store.jobs()[0].next_run_at, 3660);
        assert!(store.claim_due(3601, |_| false).unwrap().is_empty());
        drop(store);
        let mut reopened = temp.store();
        assert_eq!(reopened.jobs()[0].last_runs[0].status, "interrupted");
        assert_eq!(
            reopened.jobs()[0].active_task_id.as_deref(),
            Some("schedule-daily-review-60")
        );
        assert!(reopened.claim_due(3601, |_| false).unwrap().is_empty());
        assert!(reopened.claim_due(3660, |_| true).unwrap().is_empty());
        assert_eq!(reopened.jobs()[0].last_runs[0].status, "skipped");
        assert_eq!(reopened.claim_due(3720, |_| false).unwrap().len(), 1);
        assert_eq!(
            fs::metadata(temp.0.join("schedules.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn pause_resume_failure_and_bounded_history() {
        let temp = Temp::new();
        let mut store = temp.store();
        store.upsert(temp.spec(), 0).unwrap();
        store.set_enabled("daily-review", false, 0).unwrap();
        assert!(store.claim_due(500, |_| false).unwrap().is_empty());
        assert!(!store.jobs()[0].spec.enabled);
        store.set_enabled("daily-review", true, 500).unwrap();
        assert_eq!(store.jobs()[0].next_run_at, 540);
        for i in 9..40 {
            let now = i * 60;
            let claims = store.claim_due(now, |_| false).unwrap();
            store
                .finish(
                    &claims[0].id,
                    &claims[0].task_id,
                    now,
                    Some("Provider is unavailable".into()),
                )
                .unwrap();
        }
        assert_eq!(store.jobs()[0].last_runs.len(), MAX_HISTORY);
        assert_eq!(store.jobs()[0].last_runs.last().unwrap().status, "error");
        assert!(store.jobs()[0].active_task_id.is_some());
        store.delete("daily-review").unwrap();
        drop(store);
        assert!(temp.store().jobs().is_empty());
    }
    #[test]
    fn launch_success_retains_active_identity_and_removed_folder_loads() {
        let temp = Temp::new();
        let mut spec = temp.spec();
        let project = temp.0.join("project");
        fs::create_dir(&project).unwrap();
        spec.launch.cwd = project.to_string_lossy().into();
        let mut store = temp.store();
        store.upsert(spec, 0).unwrap();
        let claim = store.claim_due(60, |_| false).unwrap().remove(0);
        store.finish(&claim.id, &claim.task_id, 61, None).unwrap();
        fs::remove_dir(project).unwrap();
        drop(store);
        let reopened = temp.store();
        assert_eq!(reopened.jobs()[0].last_runs[0].status, "launched");
        assert_eq!(
            reopened.jobs()[0].active_task_id.as_deref(),
            Some(claim.task_id.as_str())
        );
    }
    #[test]
    fn invalid_spec_and_failed_save_leave_memory_unchanged() {
        let temp = Temp::new();
        let mut store = temp.store();
        let mut spec = temp.spec();
        spec.id = "x".repeat(33);
        assert!(store.upsert(spec, 0).is_err());
        let mut spec = temp.spec();
        spec.launch.model = "auto".into();
        assert!(store.upsert(spec, 0).is_err());
        let mut spec = temp.spec();
        spec.launch.task = "x".repeat(16385);
        assert!(store.upsert(spec, 0).is_err());
        fs::write(temp.0.join("not-a-directory"), b"x").unwrap();
        let mut blocked = ScheduleStore::load(temp.0.join("missing.json")).unwrap();
        blocked.path = temp.0.join("not-a-directory").join("schedules.json");
        assert!(blocked.upsert(temp.spec(), 0).is_err());
        assert!(blocked.jobs().is_empty());
        drop(store);
        fs::write(temp.0.join("schedules.json"), b"not JSON").unwrap();
        assert!(ScheduleStore::load(temp.0.join("schedules.json")).is_err());
    }
    #[test]
    fn exclusive_store_ownership_prevents_duplicate_daemons() {
        let temp = Temp::new();
        let store = temp.store();
        assert!(ScheduleStore::load(temp.0.join("schedules.json")).is_err());
        drop(store);
        assert!(ScheduleStore::load(temp.0.join("schedules.json")).is_ok());
    }
    #[test]
    fn failed_claim_persistence_returns_no_launch_and_does_not_advance() {
        let temp = Temp::new();
        let mut store = temp.store();
        store.upsert(temp.spec(), 0).unwrap();
        fs::write(temp.0.join("not-a-directory"), b"x").unwrap();
        store.path = temp.0.join("not-a-directory/schedules.json");
        assert!(store.claim_due(60, |_| false).is_err());
        assert_eq!(store.jobs()[0].next_run_at, 60);
        assert!(store.jobs()[0].last_runs.is_empty());
        assert!(store.jobs()[0].active_task_id.is_none());
    }

    #[test]
    fn bounded_job_count_and_unknown_launch_fields_rejected() {
        let temp = Temp::new();
        let mut store = temp.store();
        for i in 0..MAX_JOBS {
            let mut spec = temp.spec();
            spec.id = format!("job-{i}");
            store.upsert(spec, 0).unwrap();
        }
        assert!(store.upsert(temp.spec(), 0).is_err());
        let mut existing = temp.spec();
        existing.id = "job-0".into();
        existing.name = "Changed".into();
        assert!(store.upsert(existing, 0).is_ok());
        let mut value = serde_json::to_value(temp.spec().launch).unwrap();
        value["manager_task_id"] = serde_json::json!("manager");
        assert!(serde_json::from_value::<ScheduleLaunch>(value).is_err());
    }
    #[test]
    fn retrying_save_and_resume_preserves_due_occurrence_and_claim_snapshot() {
        let temp = Temp::new();
        let mut store = temp.store();
        let spec = temp.spec();
        store.upsert(spec.clone(), 0).unwrap();
        assert_eq!(store.upsert(spec.clone(), 600).unwrap().next_run_at, 60);
        assert_eq!(
            store.set_enabled(&spec.id, true, 600).unwrap().next_run_at,
            60
        );
        let claim = store.claim_due(600, |_| false).unwrap().remove(0);
        assert_eq!(claim.spec, spec);
        assert_eq!(claim.launch, spec.launch);
        let mut edited = spec.clone();
        edited.cron = "0 0 * * *".into();
        store.upsert(edited.clone(), 600).unwrap();
        assert_ne!(claim.spec, store.jobs()[0].spec);
        assert_eq!(
            claim.spec, spec,
            "editing the schedule must not mutate its claimed snapshot"
        );
        store.set_enabled(&spec.id, false, 600).unwrap();
        let next = store
            .set_enabled(&spec.id, false, 1200)
            .unwrap()
            .next_run_at;
        assert_eq!(next, store.jobs()[0].next_run_at);
        assert!(!store.jobs()[0].spec.enabled);
        let resumed = store.set_enabled(&spec.id, true, 86_401).unwrap();
        assert_eq!(resumed.next_run_at, 172_800);
        assert_eq!(
            store
                .set_enabled(&spec.id, true, 259_200)
                .unwrap()
                .next_run_at,
            resumed.next_run_at
        );
    }
}
