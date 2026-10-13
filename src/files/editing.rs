use crate::{
    core::{EditError, EditorState, Selection},
    editor::{Command, Editor, EditorModel, EditorUpdate, SessionId},
    language::IndentAdvice,
};

/// Editing capability for a registered document. It cannot replace the owned
/// editor or change file identity; file lifecycle stays in the workspace.
///
/// ```compile_fail
/// use soda::{files::Workspace, editor::{Editor, Language}};
/// let mut workspace = Workspace::default();
/// let id = workspace.new_document(Language::PlainText);
/// *workspace.editor_mut(id).unwrap() = Editor::new("replacement", Language::PlainText);
/// ```
pub struct Editing<'a> {
    pub(super) editor: &'a mut Editor,
}
impl Editing<'_> {
    pub fn model(&self) -> &EditorModel {
        self.editor.model()
    }
    pub fn state(&self) -> &EditorState {
        self.editor.state()
    }
    pub fn execute(&mut self, command: Command) -> Result<EditorUpdate, EditError> {
        self.editor.execute(command)
    }
    pub fn execute_for(
        &mut self,
        session: SessionId,
        command: Command,
    ) -> Result<EditorUpdate, EditError> {
        self.editor.execute_for(session, command)
    }
    pub fn execute_at(
        &mut self,
        session: SessionId,
        command: Command,
        time: std::time::Duration,
    ) -> Result<EditorUpdate, EditError> {
        self.editor.execute_at(session, command, time)
    }
    pub fn add_session(&mut self, selection: Selection) -> Result<SessionId, EditError> {
        self.editor.add_session(selection)
    }
    pub fn close_session(&mut self, session: SessionId) -> Result<(), EditError> {
        self.editor.close_session(session)
    }
    pub fn indentation(&mut self, line: usize) -> Result<IndentAdvice, EditError> {
        self.editor.indentation(line)
    }
}
