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
    PlainText,
    Cpp(CppSession),
}
#[derive(Clone)]
pub(super) struct LanguageSession {
    inner: Session,
}
impl LanguageSession {
    pub fn new(language: Language) -> Self {
        Self {
            inner: match language {
                Language::PlainText => Session::PlainText,
                Language::Cpp(rules) => Session::Cpp(CppSession::new(rules)),
            },
        }
    }
    pub fn description(&self) -> Language {
        match &self.inner {
            Session::PlainText => Language::PlainText,
            Session::Cpp(session) => Language::Cpp(session.rules().clone()),
        }
    }
    pub fn configure(&mut self, language: Language) {
        match (&mut self.inner, language) {
            (Session::Cpp(session), Language::Cpp(rules)) => session.set_rules(rules),
            (_, language) => *self = Self::new(language),
        }
    }
    pub fn whitespace(&self) -> crate::language::WhitespacePolicy {
        match &self.inner {
            Session::Cpp(session) => session.rules().whitespace().clone(),
            Session::PlainText => crate::language::WhitespacePolicy {
                indent_width: 4,
                tab_width: std::num::NonZeroUsize::new(4).unwrap(),
                tabs: crate::language::TabPolicy::Never,
            },
        }
    }
    pub fn triggers(&self, ch: char) -> bool {
        match &self.inner {
            Session::PlainText => false,
            Session::Cpp(session) => session.triggers(ch),
        }
    }
    pub fn enter_advice(
        &mut self,
        snapshot: &Snapshot,
        position: usize,
    ) -> Result<EnterAdvice, EditError> {
        match &mut self.inner {
            Session::PlainText => Ok(EnterAdvice::default()),
            Session::Cpp(session) => session.enter_advice(snapshot, position),
        }
    }
    pub fn indent(
        &mut self,
        snapshot: &Snapshot,
        request: IndentRequest,
    ) -> Result<IndentAdvice, EditError> {
        match &mut self.inner {
            Session::PlainText => Ok(IndentAdvice::Unavailable),
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
