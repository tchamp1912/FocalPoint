//! Persisted, pull-first inter-agent channels.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const RETENTION: usize = 100;
pub const BODY_MAX_CHARS: usize = 4_096;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: u64,
    pub channel: String,
    pub from_session: String,
    pub to: String,
    pub ts: u64,
    pub kind: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Channel {
    pub id: String,
    pub owner_session: String,
    pub owner_task_id: String,
    pub members: BTreeMap<String, u64>,
    pub messages: Vec<Message>,
    pub next_id: u64,
}

impl Channel {
    pub fn new(id: String, owner_session: String, owner_task_id: String) -> Self {
        let mut members = BTreeMap::new();
        if !owner_session.is_empty() {
            members.insert(owner_session.clone(), 0);
        }
        Self {
            id,
            owner_session,
            owner_task_id,
            members,
            messages: Vec::new(),
            next_id: 1,
        }
    }

    /// Joining at `next_id - 1` is load-bearing: a late joiner never receives
    /// any message that existed before it became a member.
    pub fn join_at_tail(&mut self, session: String) {
        self.members
            .entry(session)
            .or_insert(self.next_id.saturating_sub(1));
    }

    /// Bind the real managed orchestrator session to a channel that was
    /// created atomically with its workflow launch. Replays are idempotent,
    /// while a different session can never steal an already-bound channel.
    pub fn bind_owner(&mut self, session: String) -> Result<(), String> {
        if self.owner_session.is_empty() {
            self.owner_session = session.clone();
            self.members.entry(session).or_insert(0);
            return Ok(());
        }
        if self.owner_session == session {
            self.members.entry(session).or_insert(0);
            return Ok(());
        }
        Err("workflow channel is already bound to another orchestrator".into())
    }

    pub fn post(
        &mut self,
        from_session: String,
        to: String,
        kind: String,
        body: String,
        ts: u64,
    ) -> Message {
        let message = Message {
            id: self.next_id,
            channel: self.id.clone(),
            from_session,
            to,
            ts,
            kind,
            body,
        };
        self.next_id += 1;
        self.messages.push(message.clone());
        if self.messages.len() > RETENTION {
            let excess = self.messages.len() - RETENTION;
            self.messages.drain(..excess);
        }
        message
    }

    /// Read without acknowledging. Messages are returned oldest-first so a
    /// bounded read can safely acknowledge only the returned prefix instead
    /// of silently skipping older unread work.
    pub fn read(
        &self,
        session: &str,
        since: Option<u64>,
        limit: usize,
    ) -> Result<(Vec<Message>, u64, u64), String> {
        let stored = self
            .members
            .get(session)
            .copied()
            .ok_or_else(|| "session is not a channel member".to_string())?;
        // An explicit cursor can move a diagnostic read forward, but can
        // never rewind the durable acknowledgement cursor.
        let cursor = since.unwrap_or(stored).max(stored);
        let available_through = self.next_id.saturating_sub(1);
        let unread: Vec<Message> = self
            .messages
            .iter()
            .filter(|message| {
                message.id > cursor
                    && (message.to == session
                        || (message.to == "channel"
                            && (message.from_session == self.owner_session
                                || message.from_session == "focalpoint")))
            })
            .take(limit)
            .cloned()
            .collect();
        let next = unread.last().map(|message| message.id).unwrap_or(cursor);
        Ok((unread, next, available_through))
    }

    /// Advance one member's durable acknowledgement cursor monotonically.
    pub fn ack(&mut self, session: &str, through: u64) -> Result<u64, String> {
        let available_through = self.next_id.saturating_sub(1);
        if through > available_through {
            return Err("channel acknowledgement exceeds the available message id".into());
        }
        let stored = self
            .members
            .get_mut(session)
            .ok_or_else(|| "session is not a channel member".to_string())?;
        *stored = (*stored).max(through);
        Ok(*stored)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Channels {
    pub channels: BTreeMap<String, Channel>,
    pub next_id: u64,
}

impl Channels {
    pub fn create(&mut self, owner_session: String, owner_task_id: String) -> Channel {
        self.next_id += 1;
        let id = format!("ch-{:x}", self.next_id);
        let channel = Channel::new(id.clone(), owner_session, owner_task_id);
        self.channels.insert(id, channel.clone());
        channel
    }

    /// Reserve a channel before the workflow orchestrator has registered its
    /// provider session. `bind_owner` completes ownership during the managed
    /// registration handshake.
    pub fn create_pending(&mut self, owner_task_id: String) -> Channel {
        self.next_id += 1;
        let id = format!("ch-{:x}", self.next_id);
        let channel = Channel::new(id.clone(), String::new(), owner_task_id);
        self.channels.insert(id, channel.clone());
        channel
    }
}

pub fn valid_kind(kind: &str) -> bool {
    matches!(
        kind,
        "note" | "question" | "progress" | "blocker" | "directive"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn post_read_uses_and_advances_cursor() {
        let mut channel = Channel::new("ch-1".into(), "owner".into(), "task".into());
        channel.join_at_tail("worker".into());
        channel.post(
            "owner".into(),
            "channel".into(),
            "note".into(),
            "one".into(),
            1,
        );
        let (messages, cursor, _) = channel.read("worker", None, 20).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(cursor, 1);
        assert_eq!(channel.read("worker", None, 20).unwrap().0.len(), 1);
        assert_eq!(channel.ack("worker", cursor).unwrap(), 1);
        assert!(channel.read("worker", None, 20).unwrap().0.is_empty());
    }

    #[test]
    fn late_joiner_starts_at_tail() {
        let mut channel = Channel::new("ch-1".into(), "owner".into(), "task".into());
        channel.post(
            "owner".into(),
            "channel".into(),
            "note".into(),
            "old".into(),
            1,
        );
        channel.join_at_tail("worker".into());
        channel.post(
            "owner".into(),
            "channel".into(),
            "note".into(),
            "new".into(),
            2,
        );
        let (messages, _, _) = channel.read("worker", None, 20).unwrap();
        assert_eq!(
            messages.iter().map(|m| m.body.as_str()).collect::<Vec<_>>(),
            vec!["new"]
        );
    }

    #[test]
    fn retention_evicts_oldest_by_count() {
        let mut channel = Channel::new("ch-1".into(), "owner".into(), "task".into());
        for id in 0..=RETENTION {
            channel.post(
                "owner".into(),
                "channel".into(),
                "note".into(),
                id.to_string(),
                id as u64,
            );
        }
        assert_eq!(channel.messages.len(), RETENTION);
        assert_eq!(channel.messages[0].body, "1");
    }

    #[test]
    fn bounded_read_does_not_skip_unacknowledged_prefix() {
        let mut channel = Channel::new("ch-1".into(), "owner".into(), "task".into());
        channel.join_at_tail("worker".into());
        for body in ["one", "two", "three"] {
            channel.post(
                "owner".into(),
                "channel".into(),
                "note".into(),
                body.into(),
                1,
            );
        }
        let (first, through, available) = channel.read("worker", None, 2).unwrap();
        assert_eq!(
            first.iter().map(|m| m.body.as_str()).collect::<Vec<_>>(),
            vec!["one", "two"]
        );
        assert_eq!((through, available), (2, 3));
        channel.ack("worker", through).unwrap();
        assert_eq!(channel.read("worker", None, 2).unwrap().0[0].body, "three");
    }

    #[test]
    fn pending_channel_binds_owner_once() {
        let mut channels = Channels::default();
        let pending = channels.create_pending("workflow-run".into());
        let channel = channels.channels.get_mut(&pending.id).unwrap();
        assert!(channel.owner_session.is_empty());
        channel.bind_owner("orchestrator-session".into()).unwrap();
        assert_eq!(channel.owner_session, "orchestrator-session");
        assert!(channel.bind_owner("other-session".into()).is_err());
    }
}
