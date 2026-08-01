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
        members.insert(owner_session.clone(), 0);
        Self { id, owner_session, owner_task_id, members, messages: Vec::new(), next_id: 1 }
    }

    /// Joining at `next_id - 1` is load-bearing: a late joiner never receives
    /// any message that existed before it became a member.
    pub fn join_at_tail(&mut self, session: String) {
        self.members.entry(session).or_insert(self.next_id.saturating_sub(1));
    }

    pub fn post(&mut self, from_session: String, to: String, kind: String, body: String, ts: u64) -> Message {
        let message = Message { id: self.next_id, channel: self.id.clone(), from_session, to, ts, kind, body };
        self.next_id += 1;
        self.messages.push(message.clone());
        if self.messages.len() > RETENTION {
            let excess = self.messages.len() - RETENTION;
            self.messages.drain(..excess);
        }
        message
    }

    pub fn read(&mut self, session: &str, since: Option<u64>, tail: usize) -> Result<(Vec<Message>, u64), String> {
        let stored = self.members.get(session).copied()
            .ok_or_else(|| "session is not a channel member".to_string())?;
        // `--since` is useful after a hook restart, but must never rewind a
        // daemon cursor and re-deliver data already acknowledged by this
        // member.
        let cursor = since.unwrap_or(stored).max(stored);
        let next = self.next_id.saturating_sub(1);
        let mut unread: Vec<Message> = self.messages.iter().filter(|message| {
            message.id > cursor && (message.to == session || (message.to == "channel" && message.from_session == self.owner_session))
        }).cloned().collect();
        if unread.len() > tail { unread = unread.split_off(unread.len() - tail); }
        self.members.insert(session.to_string(), next);
        Ok((unread, next))
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
}

pub fn valid_kind(kind: &str) -> bool {
    matches!(kind, "note" | "question" | "progress" | "blocker" | "directive")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn post_read_uses_and_advances_cursor() {
        let mut channel = Channel::new("ch-1".into(), "owner".into(), "task".into());
        channel.join_at_tail("worker".into());
        channel.post("owner".into(), "channel".into(), "note".into(), "one".into(), 1);
        let (messages, cursor) = channel.read("worker", None, 20).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(cursor, 1);
        assert!(channel.read("worker", None, 20).unwrap().0.is_empty());
    }

    #[test]
    fn late_joiner_starts_at_tail() {
        let mut channel = Channel::new("ch-1".into(), "owner".into(), "task".into());
        channel.post("owner".into(), "channel".into(), "note".into(), "old".into(), 1);
        channel.join_at_tail("worker".into());
        channel.post("owner".into(), "channel".into(), "note".into(), "new".into(), 2);
        let (messages, _) = channel.read("worker", None, 20).unwrap();
        assert_eq!(messages.iter().map(|m| m.body.as_str()).collect::<Vec<_>>(), vec!["new"]);
    }

    #[test]
    fn retention_evicts_oldest_by_count() {
        let mut channel = Channel::new("ch-1".into(), "owner".into(), "task".into());
        for id in 0..=RETENTION { channel.post("owner".into(), "channel".into(), "note".into(), id.to_string(), id as u64); }
        assert_eq!(channel.messages.len(), RETENTION);
        assert_eq!(channel.messages[0].body, "1");
    }
}
