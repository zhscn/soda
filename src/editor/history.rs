use super::SessionId;
use crate::core::{EditorState, Selection, UserEvent};
use std::time::Duration;

#[derive(Clone)]
struct Previous {
    owner: SessionId,
    event: UserEvent,
    time: Duration,
    revision: u64,
    selection: Selection,
    group: u64,
}
/// Input history policy, separate from the core's history storage and replay.
#[derive(Clone, Default)]
pub(super) struct InputHistory {
    previous: Option<Previous>,
    next_group: u64,
    compound: Option<(SessionId, u64)>,
    start: Option<Selection>,
}
impl InputHistory {
    pub fn compound(&self, owner: SessionId) -> Option<u64> {
        self.compound
            .filter(|(id, _)| *id == owner)
            .map(|(_, group)| group)
    }
    pub fn begin(
        &mut self,
        owner: SessionId,
        before: Selection,
    ) -> Result<(), crate::core::EditError> {
        self.next_group = self
            .next_group
            .checked_add(1)
            .ok_or(crate::core::EditError::VersionExhausted)?;
        self.previous = None;
        self.start = Some(before);
        self.compound = Some((owner, self.next_group));
        Ok(())
    }
    pub fn take_start(&mut self, owner: SessionId) -> Option<Selection> {
        if self.compound(owner).is_some() {
            self.start.take()
        } else {
            None
        }
    }
    pub fn end(&mut self) {
        self.start = None;
        self.compound = None;
        self.previous = None;
    }
    pub fn owner_changed(&mut self, owner: SessionId) {
        if self.compound.is_some_and(|(id, _)| id != owner) {
            self.end();
        }
    }
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
