use crate::{
    core::{EditError, Snapshot},
    cpp::{CppRules, CppSession},
    language::{EnterAdvice, IndentAdvice, IndentRequest},
};
use std::sync::Arc;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub enum Language {
    #[default]
    PlainText,
    Cpp(Arc<CppRules>),
}
impl From<CppRules> for Language {
    fn from(rules: CppRules) -> Self {
        Self::Cpp(Arc::new(rules))
    }
}
impl From<&CppRules> for Language {
    fn from(rules: &CppRules) -> Self {
        rules.clone().into()
    }
}

#[derive(Clone)]
enum Session {
    /// Plain text keeps whitespace settings that options choose.
    PlainText(crate::language::WhitespacePolicy),
    Cpp(CppSession),
}
/// Plain text indents with four spaces until options say otherwise.
pub(crate) fn plain_whitespace() -> crate::language::WhitespacePolicy {
    crate::language::WhitespacePolicy {
        indent_width: 4,
        tab_width: std::num::NonZeroUsize::new(4).unwrap(),
        tabs: crate::language::TabPolicy::Never,
    }
}
#[derive(Clone)]
pub(super) struct LanguageSession {
    inner: Session,
}
impl LanguageSession {
    pub fn new(language: Language) -> Self {
        Self {
            inner: match language {
                Language::PlainText => Session::PlainText(plain_whitespace()),
                Language::Cpp(rules) => Session::Cpp(CppSession::new(rules)),
            },
        }
    }
    pub fn description(&self) -> Language {
        match &self.inner {
            Session::PlainText(_) => Language::PlainText,
            Session::Cpp(session) => Language::Cpp(session.rules().clone()),
        }
    }
    pub fn configure(&mut self, language: Language) {
        match (&mut self.inner, language) {
            (Session::Cpp(session), Language::Cpp(rules)) => session.set_rules(rules),
            (Session::PlainText(_), Language::PlainText) => {}
            (_, language) => *self = Self::new(language),
        }
    }
    /// Sets plain text whitespace; other languages keep their own rules.
    /// Returns whether anything changed.
    pub fn set_whitespace(&mut self, policy: crate::language::WhitespacePolicy) -> bool {
        match &mut self.inner {
            Session::PlainText(current) if *current != policy => {
                *current = policy;
                true
            }
            _ => false,
        }
    }
    pub fn whitespace(&self) -> crate::language::WhitespacePolicy {
        match &self.inner {
            Session::Cpp(session) => session.rules().whitespace().clone(),
            Session::PlainText(policy) => policy.clone(),
        }
    }
    /// Whether quotes are typed in pairs.
    pub fn pairs_quotes(&self) -> bool {
        matches!(self.inner, Session::Cpp(_))
    }
    /// Whether a position is inside a comment or a string or character
    /// literal, where brackets and quotes are text.
    pub fn in_literal(&mut self, snapshot: &Snapshot, position: usize) -> Result<bool, EditError> {
        match &mut self.inner {
            Session::PlainText(_) => Ok(false),
            Session::Cpp(session) => session.in_literal(snapshot, position),
        }
    }
    pub fn triggers(&self, ch: char) -> bool {
        match &self.inner {
            Session::PlainText(_) => false,
            Session::Cpp(session) => session.triggers(ch),
        }
    }
    pub fn enter_advice(
        &mut self,
        snapshot: &Snapshot,
        position: usize,
    ) -> Result<EnterAdvice, EditError> {
        match &mut self.inner {
            Session::PlainText(_) => Ok(EnterAdvice::default()),
            Session::Cpp(session) => session.enter_advice(snapshot, position),
        }
    }
    pub fn indent(
        &mut self,
        snapshot: &Snapshot,
        request: IndentRequest,
    ) -> Result<IndentAdvice, EditError> {
        match &mut self.inner {
            Session::PlainText(_) => Ok(IndentAdvice::Unavailable),
            Session::Cpp(session) => session.indent(snapshot, request),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        core::Selection,
        cpp::ParseStrategy,
        editor::{Command, Editor},
    };

    #[test]
    fn successful_input_retains_speculative_analysis_for_subsequent_edits() {
        let text = (0..100)
            .map(|i| format!("void f{i}() {{\n    work({i});\n}}\n"))
            .collect::<String>();
        let mut editor = Editor::new(text.clone(), CppRules::default());
        editor.indentation(0).unwrap();
        let caret = text.find("work(50);").unwrap() + "work(50);".len();
        editor
            .execute(Command::SetSelection(Selection::caret(caret)))
            .unwrap();
        for _ in 0..2 {
            editor.execute(Command::Enter).unwrap();
            let Session::Cpp(session) = &editor.model().document.language.inner else {
                panic!()
            };
            let work = session.analysis_work().unwrap();
            assert_eq!(work.strategy, ParseStrategy::Container);
            assert!(work.scanned_bytes < 80);
            assert!(work.reparsed_tokens < 50);
        }
        editor.execute(Command::Undo).unwrap();
        editor.indentation(0).unwrap();
        let Session::Cpp(session) = &editor.model().document.language.inner else {
            panic!()
        };
        let work = session.analysis_work().unwrap();
        assert!(work.scanned_bytes < 80);
        assert!(work.reparsed_tokens < 50);
    }
}
