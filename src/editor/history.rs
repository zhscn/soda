use super::SessionId;
use crate::core::{EditorState, Selection, UserEvent};
use std::time::Duration;

struct Previous {
    owner: SessionId,
    event: UserEvent,
    time: Duration,
    revision: u64,
    selection: Selection,
    group: u64,
}
/// Input history policy, separate from the core's history storage and replay.
#[derive(Default)]
pub(super) struct InputHistory {
    previous: Option<Previous>,
    next_group: u64,
}
impl InputHistory {
    pub fn plan(
        &self,
        owner: SessionId,
        event: UserEvent,
        time: Duration,
        state: &EditorState,
    ) -> Result<u64, crate::core::EditError> {
        if let Some(previous) = &self.previous
            && previous.owner == owner
            && previous.event == event
            && previous.revision == state.snapshot().version()
            && previous.selection == state.selection()
            && time >= previous.time
            && time - previous.time <= Duration::from_millis(500)
        {
            return Ok(previous.group);
        }
        self.next_group
            .checked_add(1)
            .ok_or(crate::core::EditError::VersionExhausted)
    }
    pub fn record(
        &mut self,
        owner: SessionId,
        event: UserEvent,
        time: Duration,
        state: &EditorState,
        group: u64,
    ) {
        self.next_group = self.next_group.max(group);
        self.previous = Some(Previous {
            owner,
            event,
            time,
            revision: state.snapshot().version(),
            selection: state.selection(),
            group,
        });
    }
    pub fn isolate(&mut self) {
        self.previous = None;
    }
}
