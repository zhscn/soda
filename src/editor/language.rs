use crate::{
    core::{EditError, Snapshot},
    cpp::{CppRules, CppSession},
    language::{
        Analyzer, EnterAdvice, Group, IndentAdvice, IndentRequest, IndentTrigger, Item, ItemKind,
        Profile, Scanner, Side, WhitespacePolicy, catalog, materialize,
    },
    rust::RustSession,
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
        /// Structure and indentation where soda knows the language beyond
        /// its grammar.
        rust: Option<RustSession>,
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
                    rust: (profile.id == "rust").then(RustSession::default),
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
            Session::TextMate {
                rust: Some(rust), ..
            } => rust.in_literal(snapshot, position),
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
            Session::TextMate {
                rust: Some(rust), ..
            } => rust.enclosing(snapshot, at),
            _ => self.scanned(snapshot, |scanner| scanner.enclosing(at)),
        }
    }
    /// The item next to a position, within the group around it; `None` at
    /// the group's end or where a delimiter has no partner.
    pub fn item(&mut self, snapshot: &Snapshot, at: usize, side: Side) -> Option<Item> {
        match &mut self.inner {
            Session::Cpp(session) => session.item(snapshot, at, side),
            Session::TextMate {
                rust: Some(rust), ..
            } => rust.item(snapshot, at, side),
            _ => self.scanned(snapshot, |scanner| scanner.item(at, side)),
        }
    }
    /// The closer of a bracket that ends the text of a line up to `end`,
    /// outside literals.
    fn opens(&self, snapshot: &Snapshot, line: usize, end: usize) -> Option<char> {
        let tokens = self.tokens()?;
        let start = snapshot.line_start(line)?;
        let text = snapshot.byte_slice(start..end)?.to_string();
        let text = text.trim_end();
        let open = text.chars().next_back()?;
        let at = start + text.len() - open.len_utf8();
        let brackets = self.profile().round_brackets();
        let (_, close) = brackets.iter().find(|(bracket, _)| *bracket == open)?;
        (!tokens.in_literal(snapshot, at)).then_some(*close)
    }
    fn opens_line(&self, snapshot: &Snapshot, line: usize) -> Option<char> {
        self.opens(snapshot, line, snapshot.line_content_range(line)?.end)
    }
    /// Whether a position has an opening bracket before it and its closer
    /// after it, with only spaces between them.
    fn between_pair(&self, snapshot: &Snapshot, position: usize) -> bool {
        let line = snapshot.line_of(position).unwrap();
        let (Some(close), Some(content)) = (
            self.opens(snapshot, line, position),
            snapshot.line_content_range(line),
        ) else {
            return false;
        };
        let after = snapshot.byte_slice(position..content.end).unwrap();
        after.to_string().trim_start().starts_with(close)
    }
    /// Languages without a parser get what brackets say and no more: a level
    /// after a line that ends in an opening bracket, and the closer of a
    /// split pair back at the level of its opener. Otherwise lines inherit.
    fn bracket_indent(&self, snapshot: &Snapshot, request: IndentRequest) -> IndentAdvice {
        let set = |prefix| IndentAdvice::Set {
            prefix,
            auxiliary: None,
        };
        let indent = |line| snapshot.leading_whitespace(line).map(|w| w.to_string());
        let Some(previous) = request.line.checked_sub(1) else {
            return IndentAdvice::Unavailable;
        };
        match request.trigger {
            IndentTrigger::Enter if self.opens_line(snapshot, previous).is_some() => {
                let style = self.whitespace();
                let width = style.tab_width.get();
                let column = indent(previous)
                    .unwrap_or_default()
                    .chars()
                    .fold(0, |column, ch| {
                        if ch == '\t' {
                            column + width - column % width
                        } else {
                            column + 1
                        }
                    });
                let target = column + style.indent_width;
                set(materialize(target, 0, target, &style))
            }
            IndentTrigger::Reindent => {
                let closer = snapshot
                    .line_content_range(request.line)
                    .and_then(|range| snapshot.byte_slice(range))
                    .and_then(|text| text.to_string().trim_start().chars().next());
                let blank = snapshot.line_content_range(previous).is_some_and(|range| {
                    snapshot
                        .byte_slice(range)
                        .unwrap()
                        .to_string()
                        .trim()
                        .is_empty()
                });
                match previous.checked_sub(1) {
                    Some(opener)
                        if blank
                            && closer.is_some()
                            && self.opens_line(snapshot, opener) == closer =>
                    {
                        indent(opener).map_or(IndentAdvice::Unavailable, set)
                    }
                    _ => IndentAdvice::Unavailable,
                }
            }
            _ => IndentAdvice::Unavailable,
        }
    }
    pub fn triggers(&self, ch: char) -> bool {
        match &self.inner {
            Session::Cpp(session) => session.triggers(ch),
            Session::TextMate {
                rust: Some(rust), ..
            } => rust.triggers(ch),
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
            Session::TextMate {
                rust: Some(rust), ..
            } => rust.enter_advice(snapshot, position),
            _ => Ok(EnterAdvice {
                expand_pair: self.between_pair(snapshot, position),
                ..EnterAdvice::default()
            }),
        }
    }
    pub fn indent(
        &mut self,
        snapshot: &Snapshot,
        request: IndentRequest,
    ) -> Result<IndentAdvice, EditError> {
        match &mut self.inner {
            Session::Cpp(session) => session.indent(snapshot, request),
            Session::TextMate {
                rust: Some(rust),
                whitespace,
                ..
            } => rust.indent(snapshot, request, whitespace),
            _ => Ok(self.bracket_indent(snapshot, request)),
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
