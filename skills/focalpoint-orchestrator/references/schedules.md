# Scheduled prompts

Use this when the user asks to run a prepared task on a recurring schedule.
Use `fpctl-agent schedule`, not OS crontab, raw socket commands, or a loop in the
current agent session. Creating a feature is not authorization to create a live
recurring job: save only the actual prompt and cadence the user requested.

## Save and inspect

```sh
fpctl-agent schedule list
fpctl-agent schedule save --id weekday-review --name 'Weekday review' \
  --cron '0 9 * * 1-5' --timezone local \
  --provider codex --model gpt-5.6-terra --agent-type direct \
  --cwd /absolute/project --task-file /absolute/prompts/review.md
fpctl-agent schedule list
```

`save` creates or replaces the stable `--id` (1–32 ASCII letters, digits, dots,
underscores, or dashes, starting with a letter or digit). First inspect the list
so you do not accidentally replace another job. Use the same id when editing a
job, rather than making a duplicate. The response contains the saved job and
next run time. Report the schedule name/id, timezone, cadence, and next run to
the user. If the daemon rejects a request, report its error; do not substitute a
different model, path, or schedule silently.

Supply exactly one of `--task 'literal prompt'` and `--task-file PATH`.
The file is read once when saved, up to 16 KiB of UTF-8. Each future occurrence
uses that snapshot; editing the source file does not change the job until it is
saved again. Prompts are literal text, never shell code. Preserve the requested
scope in the prompt, including where to leave results. A schedule launches a
normal managed provider session; the provider's own permissions and approvals
still apply. FocalPoint does not automatically answer permission prompts.

The provider, concrete model, and existing absolute project folder are required.
`--agent-type direct` (the default) adds no persona. Agent type is a transport
label; if persona instructions are required, include them in the saved prompt.
Use `--provider claude --custom-launcher /absolute/executable-script` for an
Otari or other Claude-compatible gateway and its explicitly selected model.
Optional `--title` and `--terminal-color '#RRGGBB'` customize launched sessions.
Cursor accepts `--cursor-mode headless` or `attachable`.

## Timing

The cron expression has five numeric fields: minute, hour, day of month,
month, day of week. Supported forms are `*`, lists (`1,3,5`), inclusive ranges
(`1-5`), and steps (`*/15`, `9-17/2`). Sunday is 0 or 7. Examples:

| Intent | Cron |
| --- | --- |
| Hourly | `0 * * * *` |
| Every 30 minutes | `*/30 * * * *` |
| Daily at 09:00 | `0 9 * * *` |
| Weekdays at 09:00 | `0 9 * * 1-5` |
| Monday at 09:00 | `0 9 * * 1` |

`--timezone local` follows the Mac's current timezone; `--timezone UTC` uses
UTC. Translate the user's requested time deliberately. Ask for timezone when
it is material and cannot be inferred; do not describe local time as a fixed
IANA timezone. Local daylight-saving gaps skip nonexistent times, and repeated
fall-back minutes can each run. If both day-of-month and day-of-week are
restricted, cron uses OR matching. Seconds, names, shell commands, and macros
such as `@daily` are not accepted.

The Mac must be awake and logged in, with the daemon running and the provider
authenticated. Closing the app window does not stop schedules. Missed times
while asleep/offline coalesce into one attempt on wake/startup. A prior active
run, including one waiting for approval/input, causes the occurrence to be
skipped. Completed sessions may remain open for inspection. Launches are claimed
on disk before opening a terminal; an uncertain interrupted attempt is recorded
without replaying that occurrence. The next normal occurrence can proceed once
no prior active run remains.

## Pause, resume, remove

```sh
fpctl-agent schedule pause weekday-review
fpctl-agent schedule resume weekday-review
fpctl-agent schedule delete weekday-review
```

Pausing or deleting affects future launches, not a session already started.
Resuming selects the next future occurrence and does not replay paused time.
`save --paused` stores a draft without enabling it. These commands do not need
a live managed parent session or channel. Do not infer authorization to stop a
running session from a request to pause its schedule.

`schedule list` includes `last_runs`, newest first (up to 20). `launched` means
the managed launcher acknowledged opening the session, not that the agent's
task succeeded. `error` contains a launch failure, `skipped` explains overlap,
and `interrupted` means the daemon restarted before recording the outcome.
Inspect the corresponding managed session for actual task progress or results;
schedule history is not a transcript archive. If commands are unrecognized,
update/restart the daemon and update `fpctl-agent`; reinstalling agent personas
will not enable scheduling.
