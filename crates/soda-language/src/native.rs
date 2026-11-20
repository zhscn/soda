//! Document-local structural analysis for languages with native editing rules.
use super::{EnterAdvice, Group, IndentAdvice, IndentRequest, Item, Side, WhitespacePolicy};
use soda_core::{EditError, Snapshot};

pub trait NativeSession: Send + Sync {
    /// Forks a session for editing against a different document revision.
    fn fork(&self) -> Box<dyn NativeSession>;
    fn triggers(&self, ch: char) -> bool;
    fn in_literal(&mut self, snapshot: &Snapshot, position: usize) -> Result<bool, EditError>;
    fn enclosing(&mut self, snapshot: &Snapshot, at: usize) -> Option<Group>;
    fn item(&mut self, snapshot: &Snapshot, at: usize, side: Side) -> Option<Item>;
    fn enter_advice(
        &mut self,
        snapshot: &Snapshot,
        position: usize,
    ) -> Result<EnterAdvice, EditError>;
    fn indent(
        &mut self,
        snapshot: &Snapshot,
        request: IndentRequest,
        style: &WhitespacePolicy,
    ) -> Result<IndentAdvice, EditError>;
}

impl Clone for Box<dyn NativeSession> {
    fn clone(&self) -> Self {
        self.fork()
    }
}
