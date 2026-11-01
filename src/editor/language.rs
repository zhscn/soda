use crate::{
    core::{EditError, Snapshot},
    cpp::{CppRules, CppSession},
    language::{
        Analyzer, EnterAdvice, Group, IndentAdvice, IndentRequest, Item, ItemKind, Profile,
        Scanner, Side, WhitespacePolicy, catalog,
    },
    syntax::Tokens,
};
use std::sync::Arc;

type Literals = Vec<(std::ops::Range<usize>, ItemKind)>;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub enum Language {
    #[default]
    PlainText,
    /// A language with a TextMate grammar; it has no rules of its own.
    TextMate(Arc<Profile>),
    Cpp(Arc<CppRules>),
}
impl Language {
    pub fn profile(&self) -> &Profile {
        match self {
            Self::PlainText => catalog().plain(),
            Self::TextMate(profile) => profile,
            Self::Cpp(_) => catalog().cpp(),
        }
    }
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
    PlainText(WhitespacePolicy),
    TextMate {
        profile: Arc<Profile>,
        whitespace: WhitespacePolicy,
        tokens: Tokens,
    },
    Cpp(CppSession),
}
/// Plain text indents with four spaces until options say otherwise.
pub(crate) fn plain_whitespace() -> WhitespacePolicy {
    WhitespacePolicy {
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
                Language::TextMate(profile) => Session::TextMate {
                    tokens: Tokens::new(match &profile.analyzer {
                        Analyzer::TextMate { scope } => scope,
                        _ => "",
                    }),
                    profile,
                    whitespace: plain_whitespace(),
                },
                Language::Cpp(rules) => Session::Cpp(CppSession::new(rules)),
            },
        }
    }
    pub fn description(&self) -> Language {
        match &self.inner {
            Session::PlainText(_) => Language::PlainText,
            Session::TextMate { profile, .. } => Language::TextMate(profile.clone()),
            Session::Cpp(session) => Language::Cpp(session.rules().clone()),
        }
    }
    pub fn configure(&mut self, language: Language) {
        match (&mut self.inner, language) {
            (Session::Cpp(session), Language::Cpp(rules)) => session.set_rules(rules),
            (Session::PlainText(_), Language::PlainText) => {}
            (_, language) => {
                // What options chose outlives a change between languages
                // that take them.
                let chosen = self.chosen_whitespace().cloned();
                *self = Self::new(language);
                if let Some(policy) = chosen {
                    self.set_whitespace(policy);
                }
            }
        }
    }
    fn chosen_whitespace(&self) -> Option<&WhitespacePolicy> {
        match &self.inner {
            Session::PlainText(whitespace) | Session::TextMate { whitespace, .. } => {
                Some(whitespace)
            }
            Session::Cpp(_) => None,
        }
    }
    /// Sets the whitespace options choose; C++ keeps its own rules. Returns
    /// whether anything changed.
    pub fn set_whitespace(&mut self, policy: WhitespacePolicy) -> bool {
        match &mut self.inner {
            Session::PlainText(current)
            | Session::TextMate {
                whitespace: current,
                ..
            } if *current != policy => {
                *current = policy;
                true
            }
            _ => false,
        }
    }
    pub fn whitespace(&self) -> WhitespacePolicy {
        match &self.inner {
            Session::Cpp(session) => session.rules().whitespace().clone(),
            Session::PlainText(policy)
            | Session::TextMate {
                whitespace: policy, ..
            } => policy.clone(),
        }
    }
    pub fn profile(&self) -> &Profile {
        match &self.inner {
            Session::PlainText(_) => catalog().plain(),
            Session::TextMate { profile, .. } => profile,
            Session::Cpp(_) => catalog().cpp(),
        }
    }
    /// The TextMate results of the document, in languages that have them.
    pub fn tokens(&self) -> Option<&Tokens> {
        match &self.inner {
            Session::TextMate { tokens, .. } => Some(tokens),
            _ => None,
        }
    }
    /// Whether this quote is typed in pairs.
    pub fn pairs_quote(&self, quote: char) -> bool {
        self.profile().quotes.contains(&quote)
    }
    /// Whether a position is inside a comment or a string or character
    /// literal, where brackets and quotes are text.
    pub fn in_literal(&mut self, snapshot: &Snapshot, position: usize) -> Result<bool, EditError> {
        match &mut self.inner {
            Session::Cpp(session) => session.in_literal(snapshot, position),
            Session::TextMate { tokens, .. } => {
                if !snapshot.is_char_boundary(position) {
                    return Err(EditError::InvalidRange);
                }
                Ok(tokens.in_literal(snapshot, position))
            }
            Session::PlainText(_) => Ok(false),
        }
    }
    /// Calls `ask` on a scanner of the text, in languages with no parser.
    fn scanned<T>(
        &self,
        snapshot: &Snapshot,
        ask: impl FnOnce(&mut Scanner<'_, Box<dyn FnMut(usize) -> Literals + '_>>) -> T,
    ) -> T {
        let brackets = self.profile().round_brackets();
        let tokens = self.tokens();
        let literals: Box<dyn FnMut(usize) -> Literals + '_> =
            Box::new(move |line| tokens.map_or(vec![], |tokens| tokens.literals(snapshot, line)));
        ask(&mut Scanner {
            snapshot,
            brackets: &brackets,
            literals,
        })
    }
    /// The innermost balanced group around a position.
    pub fn enclosing(&mut self, snapshot: &Snapshot, at: usize) -> Option<Group> {
        match &mut self.inner {
            Session::Cpp(session) => session.enclosing(snapshot, at),
            _ => self.scanned(snapshot, |scanner| scanner.enclosing(at)),
        }
    }
    /// The item next to a position, within the group around it; `None` at
    /// the group's end or where a delimiter has no partner.
    pub fn item(&mut self, snapshot: &Snapshot, at: usize, side: Side) -> Option<Item> {
        match &mut self.inner {
            Session::Cpp(session) => session.item(snapshot, at, side),
            _ => self.scanned(snapshot, |scanner| scanner.item(at, side)),
        }
    }
    pub fn triggers(&self, ch: char) -> bool {
        match &self.inner {
            Session::Cpp(session) => session.triggers(ch),
            _ => false,
        }
    }
    pub fn enter_advice(
        &mut self,
        snapshot: &Snapshot,
        position: usize,
    ) -> Result<EnterAdvice, EditError> {
        match &mut self.inner {
            Session::Cpp(session) => session.enter_advice(snapshot, position),
            _ => Ok(EnterAdvice::default()),
        }
    }
    pub fn indent(
        &mut self,
        snapshot: &Snapshot,
        request: IndentRequest,
    ) -> Result<IndentAdvice, EditError> {
        match &mut self.inner {
            Session::Cpp(session) => session.indent(snapshot, request),
            _ => Ok(IndentAdvice::Unavailable),
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
