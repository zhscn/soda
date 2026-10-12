use super::indent_rules::{
    AlignmentAnchor, IndentRule, IndentSegment, IndentSlot as S, OffsetRule, offset, rule,
};
use super::{
    CppRules, NodeKind as N, PPDirectiveIndent, SyntaxTree, TokenKind as K, column_width,
    materialize, parse_snapshot_with_options, parse_with_options,
};
use crate::core::{Change, EditError, EditorState, Selection, Snapshot, Transaction};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IndentRole {
    File,
    NamespaceBody,
    TypeBody,
    AccessSpecifierLabel,
    FunctionBody,
    CompoundBody,
    LambdaBody,
    SingleStatementBody,
    ControlHeaderContinuation,
    CaseLabel,
    CaseBody,
    ConstructorInitializerIntro,
    ConstructorInitializerItem,
    ParenContinuation,
    BracketContinuation,
    TemplateArgsContinuation,
    BraceInit,
    StatementContinuation,
    PreprocessorDirective,
    ClosingToken,
    PreservedRawString,
    PreservedBlockComment,
    PreservedString,
    PreservedMacro,
    Opaque,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IndentDecision {
    pub structural_column: usize,
    pub continuation_column: usize,
    pub target_column: usize,
    pub whitespace: String,
    pub role: IndentRole,
    pub anchor: Option<usize>,
    pub preserve: bool,
    pub fallback: bool,
    /// Additional local spacing for a preprocessor keyword after `#`.
    pub directive_spacing: Option<Change>,
}
struct Computer<'a> {
    snapshot: &'a Snapshot,
    tree: &'a SyntaxTree,
    line: usize,
    style: &'a CppRules,
}
impl Computer<'_> {
    fn line_of(&self, p: usize) -> usize {
        self.snapshot.line_of(p).unwrap()
    }
    fn indent(&self, line: usize) -> usize {
        column_width(
            leading(self.snapshot.line(line).unwrap()),
            0,
            self.style.whitespace.tab_width,
        )
    }
    fn column(&self, p: usize) -> usize {
        column_width(
            &self.snapshot.text()[self.snapshot.line_start(self.line_of(p)).unwrap()..p],
            0,
            self.style.whitespace.tab_width,
        )
    }
    fn decision(
        &self,
        role: IndentRole,
        structural: usize,
        continuation: usize,
        target: usize,
        anchor: Option<usize>,
    ) -> IndentDecision {
        IndentDecision {
            structural_column: structural,
            continuation_column: continuation,
            target_column: target,
            whitespace: materialize(structural, continuation, target, &self.style.whitespace),
            role,
            anchor,
            preserve: false,
            fallback: false,
            directive_spacing: None,
        }
    }
    fn fixed(&self, role: IndentRole, col: usize, anchor: Option<usize>) -> IndentDecision {
        self.decision(role, col, col, col, anchor)
    }
    fn offset_decision(
        &self,
        role: IndentRole,
        rule: OffsetRule,
        base: usize,
        anchor: Option<usize>,
    ) -> IndentDecision {
        let target = rule.target(base);
        match rule.segment {
            IndentSegment::Structural => self.fixed(role, target, anchor),
            IndentSegment::Continuation => self.decision(role, base, target, target, anchor),
        }
    }
    fn slot(
        &self,
        role: IndentRole,
        slot: S,
        base: usize,
        anchor: Option<usize>,
    ) -> IndentDecision {
        self.offset_decision(role, offset(self.style, slot), base, anchor)
    }
    fn aligned_slot(
        &self,
        role: IndentRole,
        slot: S,
        owner: usize,
        base: usize,
        origin: Option<usize>,
    ) -> IndentDecision {
        match rule(self.style, slot) {
            IndentRule::Offset(offset) => self.offset_decision(role, offset, base, origin),
            IndentRule::Align {
                anchor,
                columns,
                fallback,
            } => {
                let point = match anchor {
                    AlignmentAnchor::ConstructorColon => {
                        if self.tree.nodes[owner].kind == N::CtorInitializerList {
                            Some(self.tree.range(owner).start)
                        } else {
                            None
                        }
                    }
                    AlignmentAnchor::FirstInitializer => self.tree.nodes[owner]
                        .children
                        .iter()
                        .find(|&&child| self.tree.nodes[child].kind == N::CtorInitializer)
                        .map(|&child| self.tree.range(child).start),
                    AlignmentAnchor::FirstElement => {
                        self.tree.tokens[self.tree.nodes[owner].tokens.start + 1
                            ..self.tree.nodes[owner].tokens.end]
                            .iter()
                            .find(|t| !t.kind.is_trivia())
                            .filter(|t| {
                                self.line_of(t.range.start)
                                    == self.line_of(self.tree.range(owner).start)
                            })
                            .map(|t| t.range.start)
                    }
                };
                if let Some(point) = point {
                    self.decision(
                        role,
                        base,
                        base,
                        self.column(point).saturating_add_signed(columns),
                        Some(point),
                    )
                } else {
                    self.offset_decision(role, fallback, base, origin)
                }
            }
        }
    }
    fn origin(&self, id: usize) -> usize {
        let node = &self.tree.nodes[id];
        if matches!(
            node.kind,
            N::CompoundStatement | N::ClassBody | N::NamespaceBody | N::BraceGroup
        ) && let Some(parent) = node.parent
            && matches!(
                self.tree.nodes[parent].kind,
                N::FunctionDefinition
                    | N::OpaqueDeclaration
                    | N::ClassDecl
                    | N::NamespaceDecl
                    | N::IfStatement
                    | N::ElseClause
                    | N::ForStatement
                    | N::WhileStatement
                    | N::DoStatement
                    | N::SwitchStatement
            )
        {
            return self.tree.range(parent).start;
        }
        self.tree.range(id).start
    }
    fn first(&self, line: usize) -> Option<usize> {
        let r = self.snapshot.line_content_range(line)?;
        let start = self
            .tree
            .tokens
            .partition_point(|t| t.range.start < r.start);
        (start..self.tree.tokens.len())
            .take_while(|&i| self.tree.tokens[i].range.start < r.end)
            .find(|&i| {
                !self.tree.tokens[i].kind.is_trivia() && self.tree.tokens[i].kind != K::EndOfFile
            })
    }
    fn run(&self) -> IndentDecision {
        if !self.style.enabled {
            let mut d = self.fixed(IndentRole::Opaque, self.indent(self.line), None);
            d.preserve = true;
            d.whitespace = leading(self.snapshot.line(self.line).unwrap()).into();
            return d;
        }
        let start = self.snapshot.line_start(self.line).unwrap();
        if let Some(t) = self.tree.tokens.iter().find(|t| {
            t.range.start < start
                && (start < t.range.end || (t.unterminated && start == t.range.end))
        }) {
            let role = match t.kind {
                K::RawStringLiteral => Some(IndentRole::PreservedRawString),
                K::BlockComment => Some(IndentRole::PreservedBlockComment),
                K::StringLiteral | K::CharacterLiteral => Some(IndentRole::PreservedString),
                _ => None,
            };
            if let Some(role) = role {
                let mut d = self.fixed(role, self.indent(self.line), Some(t.range.start));
                d.preserve = true;
                d.whitespace = leading(self.snapshot.line(self.line).unwrap()).into();
                return d;
            }
        }
        let mut enclosing = Some(self.tree.node_at(start));
        while let Some(id) = enclosing {
            if self.tree.nodes[id].whitespace_sensitive && self.tree.range(id).start < start {
                let mut decision = self.fixed(
                    IndentRole::PreservedMacro,
                    self.indent(self.line),
                    Some(self.tree.range(id).start),
                );
                decision.preserve = true;
                decision.whitespace = leading(self.snapshot.line(self.line).unwrap()).into();
                return decision;
            }
            enclosing = self.tree.nodes[id].parent;
        }
        let first = self.first(self.line);
        if let Some(i) = first {
            let token = &self.tree.tokens[i];
            let id = self.tree.node_at(token.range.start);
            match token.kind {
                K::RBrace | K::RParen | K::RBracket
                    if matches!(
                        self.tree.nodes[id].kind,
                        N::CompoundStatement
                            | N::BraceGroup
                            | N::NamespaceBody
                            | N::ClassBody
                            | N::ParenGroup
                            | N::BracketGroup
                    ) =>
                {
                    let anchor = self.origin(id);
                    return self.fixed(
                        IndentRole::ClosingToken,
                        self.indent(self.line_of(anchor)),
                        Some(anchor),
                    );
                }
                K::PreprocessorHash => {
                    let depth = self.pp_column();
                    let mut decision = self.fixed(
                        IndentRole::PreprocessorDirective,
                        if self.style.directive.layout == PPDirectiveIndent::BeforeHash {
                            depth
                        } else {
                            0
                        },
                        None,
                    );
                    {
                        let start = token.range.end;
                        let len = leading(&self.snapshot.text()[start..]).len();
                        let spaces = " ".repeat(
                            if self.style.directive.layout == PPDirectiveIndent::AfterHash {
                                depth
                            } else {
                                0
                            },
                        );
                        if self.snapshot.text()[start..start + len] != spaces {
                            decision.directive_spacing =
                                Some(Change::new(start..start + len, spaces));
                        }
                    }
                    return decision;
                }
                K::CaseKw | K::DefaultKw => {
                    if let Some(switch) = self.tree.ancestor(id, N::SwitchStatement) {
                        let anchor = self.tree.range(switch).start;
                        return self.slot(
                            IndentRole::CaseLabel,
                            S::CaseLabel,
                            self.indent(self.line_of(anchor)),
                            Some(anchor),
                        );
                    }
                }
                K::PublicKw | K::ProtectedKw | K::PrivateKw
                    if self.tree.nodes[id].kind == N::AccessSpecifierLabel =>
                {
                    if let Some(class) = self.tree.ancestor(id, N::ClassDecl) {
                        let label = &self.tree.nodes[id];
                        let has_colon = self.tree.tokens[label.tokens.clone()]
                            .iter()
                            .any(|t| t.kind == K::Colon);
                        if has_colon {
                            let anchor = self.tree.range(class).start;
                            return self.slot(
                                IndentRole::AccessSpecifierLabel,
                                S::AccessLabel,
                                self.indent(self.line_of(anchor)),
                                Some(anchor),
                            );
                        }
                    }
                }
                K::Colon if self.tree.nodes[id].kind == N::CtorInitializerList => {
                    let function = self.tree.ancestor(id, N::FunctionDefinition);
                    let anchor = function.map(|id| self.tree.range(id).start);
                    let base = anchor.map_or(0, |p| self.indent(self.line_of(p)));
                    return self.slot(
                        IndentRole::ConstructorInitializerIntro,
                        S::ConstructorIntro,
                        base,
                        anchor,
                    );
                }
                _ => {}
            }
        } else {
            let line = self.snapshot.line(self.line).unwrap().trim_start();
            if line.starts_with("//") || line.starts_with("/*") {
                for next in self.line + 1..self.snapshot.line_count() {
                    if self.first(next).is_some() {
                        let other = Self {
                            line: next,
                            ..*self
                        }
                        .run();
                        if !other.preserve && other.target_column == self.indent(self.line) {
                            return other;
                        }
                        break;
                    }
                }
            }
        }
        self.generic(first)
    }
    fn ctor(&self, list: usize) -> IndentDecision {
        let anchor = self
            .tree
            .ancestor(list, N::FunctionDefinition)
            .map(|id| self.tree.range(id).start);
        let base = anchor.map_or(0, |p| self.indent(self.line_of(p)));
        self.aligned_slot(
            IndentRole::ConstructorInitializerItem,
            S::ConstructorItem,
            list,
            base,
            anchor,
        )
    }

    fn generic(&self, first: Option<usize>) -> IndentDecision {
        let query = first
            .map(|i| self.tree.tokens[i].range.start)
            .unwrap_or(self.snapshot.line_start(self.line).unwrap());
        let mut id = if first.is_some() {
            self.tree.node_at(query)
        } else {
            let prev =
                self.tree.tokens.iter().rfind(|t| {
                    !t.kind.is_trivia() && t.kind != K::EndOfFile && t.range.end <= query
                });
            let mut node = self.tree.node_at(prev.map_or(query, |t| t.range.start));
            while node != 0
                && !self.tree.nodes[node].incomplete
                && self.tree.range(node).end <= query
            {
                node = self.tree.nodes[node].parent.unwrap();
            }
            node
        };
        let mut extra = 0;
        loop {
            if self.line_of(self.tree.range(id).start) < self.line {
                break;
            }
            if self.tree.nodes[id].kind == N::PPReopenedScope {
                extra += self.style.whitespace.indent_width;
            }
            match self.tree.nodes[id].parent {
                Some(parent) => id = parent,
                None => return self.fixed(IndentRole::File, 0, None),
            }
        }
        let node = &self.tree.nodes[id];
        let anchor = self.origin(id);
        let base = self.indent(self.line_of(anchor));
        let w = self.style.whitespace.indent_width;
        let fixed = |role, col| self.fixed(role, col, Some(anchor));
        let expression = |role| {
            super::expression::continuation(self.snapshot, self.tree, self.line, id, self.style)
                .map(|column| {
                    self.decision(
                        role,
                        column.structural,
                        column.continuation,
                        column.target,
                        Some(anchor),
                    )
                })
        };
        let mut result = match node.kind {
            N::TranslationUnit => self.fixed(IndentRole::File, 0, None),
            N::NamespaceBody => {
                let nested = node
                    .parent
                    .is_some_and(|p| self.tree.ancestor(p, N::NamespaceBody).is_some());
                let is_extern = node
                    .parent
                    .is_some_and(|parent| self.tree.nodes[parent].extern_linkage);
                let slot = match (is_extern, nested) {
                    (false, false) => S::NamespaceOuter,
                    (false, true) => S::NamespaceInner,
                    (true, false) => S::ExternOuter,
                    (true, true) => S::ExternInner,
                };
                self.slot(IndentRole::NamespaceBody, slot, base, Some(anchor))
            }
            N::ClassBody
                if node.parent.is_some_and(|parent| {
                    self.tree.tokens[self.tree.nodes[parent].tokens.start].kind == K::EnumKw
                }) =>
            {
                self.slot(IndentRole::TypeBody, S::EnumBody, base, Some(anchor))
            }
            N::ClassBody => {
                let after_access = node.children.iter().any(|&child| {
                    self.tree.nodes[child].kind == N::AccessSpecifierLabel
                        && self.tree.range(child).end <= query
                });
                self.slot(
                    IndentRole::TypeBody,
                    if after_access {
                        S::MembersAfterAccess
                    } else {
                        S::MembersBeforeAccess
                    },
                    base,
                    Some(anchor),
                )
            }
            N::CompoundStatement => {
                let parent = node.parent.map(|id| self.tree.nodes[id].kind);
                if parent == Some(N::SwitchStatement)
                    && let Some(&section) = node.children.iter().rfind(|&&child| {
                        self.tree.nodes[child].kind == N::CaseSection
                            && self.tree.range(child).end <= query
                    })
                {
                    let label = self.indent(self.line_of(self.tree.range(section).start));
                    let mut d = fixed(
                        IndentRole::CaseBody,
                        offset(self.style, S::CaseBody).target(label),
                    );
                    d.anchor = Some(self.tree.range(section).start);
                    return d;
                }
                let role = match parent {
                    Some(N::FunctionDefinition) => IndentRole::FunctionBody,
                    Some(
                        N::ParenGroup | N::BracketGroup | N::BraceGroup | N::OpaqueDeclaration,
                    ) => IndentRole::LambdaBody,
                    _ => IndentRole::CompoundBody,
                };
                self.slot(role, S::BlockBody, base, Some(anchor))
            }
            N::BraceGroup => expression(IndentRole::BraceInit).unwrap_or_else(|| {
                self.aligned_slot(
                    IndentRole::BraceInit,
                    S::BracedInitializer,
                    id,
                    base,
                    Some(anchor),
                )
            }),
            N::CaseSection => self.slot(IndentRole::CaseBody, S::CaseBody, base, Some(anchor)),
            N::ParenGroup | N::BracketGroup | N::TemplateArgumentList => {
                let role = match node.kind {
                    N::ParenGroup => IndentRole::ParenContinuation,
                    N::BracketGroup => IndentRole::BracketContinuation,
                    _ => IndentRole::TemplateArgsContinuation,
                };
                expression(role).unwrap_or_else(|| {
                    self.aligned_slot(role, S::ParameterContinuation, id, base, Some(anchor))
                })
            }
            N::CtorInitializer | N::CtorInitializerList => {
                self.ctor(if node.kind == N::CtorInitializer {
                    node.parent.unwrap()
                } else {
                    id
                })
            }
            N::FunctionDefinition => {
                let list = node.children.iter().copied().find(|&child| {
                    self.tree.nodes[child].kind == N::CtorInitializerList
                        && self.tree.range(child).end <= query
                });
                let body = node.children.iter().any(|&child| {
                    self.tree.nodes[child].kind == N::CompoundStatement
                        && self.tree.range(child).start < query
                });
                if let Some(list) = list.filter(|_| !body) {
                    self.ctor(list)
                } else if offset(self.style, S::WrappedFunctionName).columns == 0
                    && self.wrapped_name(id)
                {
                    self.slot(
                        IndentRole::StatementContinuation,
                        S::WrappedFunctionName,
                        base,
                        Some(anchor),
                    )
                } else {
                    expression(IndentRole::StatementContinuation).unwrap_or_else(|| {
                        self.slot(
                            IndentRole::StatementContinuation,
                            S::StatementContinuation,
                            base,
                            Some(anchor),
                        )
                    })
                }
            }
            N::IfStatement if first.is_some_and(|i| self.tree.tokens[i].kind == K::ElseKw) => {
                fixed(IndentRole::Opaque, base)
            }
            N::DoStatement if first.is_some_and(|i| self.tree.tokens[i].kind == K::WhileKw) => {
                fixed(IndentRole::Opaque, base)
            }
            N::IfStatement
            | N::ElseClause
            | N::ForStatement
            | N::WhileStatement
            | N::DoStatement => self.slot(
                IndentRole::SingleStatementBody,
                S::SingleStatementBody,
                base,
                Some(anchor),
            ),
            N::SwitchStatement => fixed(IndentRole::Opaque, base + w),
            N::PreprocessorDirective => self.slot(
                IndentRole::PreprocessorDirective,
                S::PreprocessorBody,
                base,
                Some(anchor),
            ),
            N::PPReopenedScope => fixed(
                if first.is_some_and(|i| {
                    self.tree.tokens[i].kind == K::RBrace
                        && self.tree.range(id).end == self.tree.tokens[i].range.end
                }) {
                    IndentRole::ClosingToken
                } else {
                    IndentRole::Opaque
                },
                if first.is_some_and(|i| self.tree.tokens[i].kind == K::RBrace) {
                    base.saturating_sub(w)
                } else {
                    base
                },
            ),
            N::Error => {
                let mut d = fixed(IndentRole::Opaque, self.indent(self.line.saturating_sub(1)));
                d.fallback = true;
                d
            }
            _ => {
                if offset(self.style, S::WrappedFunctionName).columns == 0 && self.wrapped_name(id)
                {
                    self.slot(
                        IndentRole::StatementContinuation,
                        S::WrappedFunctionName,
                        base,
                        Some(anchor),
                    )
                } else {
                    expression(IndentRole::StatementContinuation).unwrap_or_else(|| {
                        self.slot(
                            IndentRole::StatementContinuation,
                            S::StatementContinuation,
                            base,
                            Some(anchor),
                        )
                    })
                }
            }
        };
        if extra > 0 {
            result.structural_column += extra;
            result.continuation_column += extra;
            result.target_column += extra;
            result.whitespace = materialize(
                result.structural_column,
                result.continuation_column,
                result.target_column,
                &self.style.whitespace,
            );
        }
        result
    }
    fn wrapped_name(&self, id: usize) -> bool {
        let node = &self.tree.nodes[id];
        if !matches!(node.kind, N::FunctionDefinition | N::OpaqueDeclaration)
            || !node.parent.is_some_and(|p| {
                matches!(
                    self.tree.nodes[p].kind,
                    N::TranslationUnit | N::NamespaceBody | N::ClassBody
                )
            })
        {
            return false;
        }
        let Some(&params) = node
            .children
            .iter()
            .find(|&&child| self.tree.nodes[child].kind == N::ParenGroup)
        else {
            return false;
        };
        let open = self.tree.nodes[params].tokens.start;
        if self.line_of(self.tree.tokens[open].range.start) != self.line {
            return false;
        }
        let mut prev = K::EndOfFile;
        let mut i = node.tokens.start;
        while i < open {
            if let Some(&child) = node.children.iter().find(|&&c| {
                self.tree.nodes[c].tokens.contains(&i)
                    && matches!(
                        self.tree.nodes[c].kind,
                        N::TemplateArgumentList | N::BracketGroup
                    )
            }) {
                i = self.tree.nodes[child].tokens.end;
                prev = K::Greater;
                continue;
            }
            let k = self.tree.tokens[i].kind;
            i += 1;
            if k.is_trivia() {
                continue;
            }
            if !matches!(
                k,
                K::Identifier
                    | K::ColonColon
                    | K::Arrow
                    | K::OperatorKw
                    | K::Star
                    | K::Amp
                    | K::AmpAmp
                    | K::Tilde
            ) && prev != K::OperatorKw
            {
                return false;
            }
            prev = k;
        }
        true
    }
    fn pp_column(&self) -> usize {
        if self.style.directive.layout == PPDirectiveIndent::None {
            return 0;
        }
        let dirs: Vec<_> = self
            .tree
            .tokens
            .iter()
            .enumerate()
            .filter(|(_, t)| t.kind == K::PreprocessorHash)
            .map(|(i, t)| {
                let words: Vec<_> = self.tree.tokens[i + 1..]
                    .iter()
                    .take_while(|t| t.preprocessor)
                    .filter(|t| !t.kind.is_trivia())
                    .map(|t| &self.snapshot.text()[t.range.clone()])
                    .collect();
                (self.line_of(t.range.start), words)
            })
            .collect();
        let last_code_line = self
            .tree
            .tokens
            .iter()
            .rev()
            .find(|t| !t.kind.is_trivia() && t.kind != K::EndOfFile)
            .map(|t| self.line_of(t.range.start));
        let guard = dirs.len() >= 3
            && last_code_line.is_some_and(|line| line <= dirs.last().unwrap().0)
            && dirs[0].1.first() == Some(&"ifndef")
            && dirs[1].1.first() == Some(&"define")
            && dirs[0].1.get(1).is_some()
            && dirs[0].1.get(1) == dirs[1].1.get(1)
            && dirs
                .last()
                .is_some_and(|(_, w)| w.first() == Some(&"endif"));
        let mut level = 0usize;
        for (line, words) in dirs {
            let own = match words.first().copied().unwrap_or("") {
                "if" | "ifdef" | "ifndef" => {
                    let own = level;
                    level += 1;
                    own
                }
                "else" | "elif" | "elifdef" | "elifndef" => level.saturating_sub(1),
                "endif" => {
                    level = level.saturating_sub(1);
                    level
                }
                _ => level,
            };
            if line == self.line {
                return own.saturating_sub(usize::from(guard)) * self.style.directive.width;
            }
        }
        0
    }
}
fn leading(text: &str) -> &str {
    &text[..text
        .bytes()
        .take_while(|&b| b == b' ' || b == b'\t')
        .count()]
}

pub fn compute_indent(
    snapshot: &Snapshot,
    tree: &SyntaxTree,
    line: usize,
    style: &CppRules,
) -> Result<IndentDecision, EditError> {
    if tree.parser_options() != &style.parser
        || (!std::ptr::eq(tree.source(), snapshot.text()) && tree.source() != snapshot.text())
    {
        return Err(EditError::AnalysisMismatch);
    }
    if line >= snapshot.line_count() {
        return Err(EditError::InvalidRange);
    }
    Ok(Computer {
        snapshot,
        tree,
        line,
        style,
    }
    .run())
}

/// Constructs one atomic operation using a temporary post-newline snapshot.
/// The returned transaction still addresses the original state.
pub fn enter(state: &EditorState, style: &CppRules) -> Result<Transaction, EditError> {
    let snapshot = state.snapshot();
    let range = state.selection().range();
    let source = snapshot.text();
    let mut base = source.to_owned();
    base.replace_range(range.clone(), "");
    let caret = range.start;
    let tree = parse_with_options(&base, &style.parser);
    let prev = tree
        .tokens
        .iter()
        .rfind(|t| t.range.end <= caret && !t.kind.is_trivia() && t.kind != K::EndOfFile);
    let next = tree
        .tokens
        .iter()
        .find(|t| t.range.start >= caret && !t.kind.is_trivia() && t.kind != K::EndOfFile);
    let between = match (prev, next) {
        (Some(left), Some(right)) if left.kind == K::LBrace && right.kind == K::RBrace => {
            let id = tree.node_at(left.range.start);
            tree.range(id).end == right.range.end
                && !base[left.range.end..right.range.start].contains(['\n', '\r'])
                && base[left.range.end..right.range.start].trim().is_empty()
        }
        _ => false,
    };
    let newline = if source.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let inserted = if between {
        format!("{newline}{newline}")
    } else {
        newline.into()
    };
    base.insert_str(caret, &inserted);
    let spec = EditorState::new(base);
    let analysis = parse_snapshot_with_options(spec.snapshot(), &style.parser);
    let middle = spec.snapshot().line_of(caret + newline.len()).unwrap();
    let d = compute_indent(spec.snapshot(), &analysis, middle, style)?;
    let ws = if d.preserve {
        if matches!(
            d.role,
            IndentRole::PreservedBlockComment | IndentRole::PreservedMacro
        ) || !style.enabled
        {
            leading(spec.snapshot().line(middle - 1).unwrap()).to_owned()
        } else {
            String::new()
        }
    } else {
        d.whitespace
    };
    let mut replacement = format!("{newline}{ws}");
    let mut end = range.end;
    if between {
        let close = compute_indent(spec.snapshot(), &analysis, middle + 1, style)?;
        replacement.push_str(newline);
        replacement.push_str(&close.whitespace);
        // Replace the existing inter-brace spaces rather than duplicating them.
        while end < source.len() && matches!(source.as_bytes()[end], b' ' | b'\t') {
            end += 1;
        }
    }
    let mut changes = vec![Change::new(range.start..end, replacement)];
    if !between && let Some(spacing) = d.directive_spacing {
        let translate = |p| range.end + (p - caret - newline.len());
        changes.push(Change::new(
            translate(spacing.range.start)..translate(spacing.range.end),
            spacing.insert,
        ));
    }
    let mut tx = Transaction::new(snapshot.version(), changes);
    tx.selection = Some(Selection::caret(range.start + newline.len() + ws.len()));
    Ok(tx)
}

pub fn reindent(
    state: &EditorState,
    line: usize,
    style: &CppRules,
) -> Result<Transaction, EditError> {
    let snapshot = state.snapshot();
    let tree = parse_snapshot_with_options(snapshot, &style.parser);
    let d = compute_indent(snapshot, &tree, line, style)?;
    let start = snapshot.line_start(line).ok_or(EditError::InvalidRange)?;
    let len = leading(snapshot.line(line).unwrap()).len();
    let mut changes = if d.preserve || snapshot.text()[start..start + len] == d.whitespace {
        vec![]
    } else {
        vec![Change::new(start..start + len, d.whitespace)]
    };
    if !d.preserve
        && let Some(spacing) = d.directive_spacing
    {
        changes.push(spacing);
    }
    Ok(Transaction::new(snapshot.version(), changes))
}

/// A committed text character, distinct from paste or IME composition. Label
/// and closing-token adjustments belong to the same undo operation as input.
pub fn type_char(
    state: &EditorState,
    ch: char,
    style: &CppRules,
) -> Result<Transaction, EditError> {
    let range = state.selection().range();
    let mut insert = Transaction::new(
        state.snapshot().version(),
        vec![Change::new(range.clone(), ch.to_string())],
    );
    insert.selection = Some(Selection::caret(range.start + ch.len_utf8()));
    let (spec, _) = state.apply(insert.clone())?;
    if !matches!(ch, ':' | '}' | '#') {
        return Ok(insert);
    }
    let line = spec.snapshot().line_of(range.start).unwrap();
    let start = spec.snapshot().line_start(line).unwrap();
    let prefix = &spec.snapshot().text()[start..range.start];
    if ch != ':' && !prefix.bytes().all(|b| matches!(b, b' ' | b'\t')) {
        return Ok(insert);
    }
    let tree = parse_snapshot_with_options(spec.snapshot(), &style.parser);
    let decision = compute_indent(spec.snapshot(), &tree, line, style)?;
    if decision.preserve
        || (ch == ':'
            && !matches!(
                decision.role,
                IndentRole::CaseLabel
                    | IndentRole::AccessSpecifierLabel
                    | IndentRole::ConstructorInitializerIntro
            ))
    {
        return Ok(insert);
    }
    let prefix_len = leading(spec.snapshot().line(line).unwrap()).len();
    if range.start < start + prefix_len {
        return Ok(insert);
    }
    if leading(spec.snapshot().line(line).unwrap()) == decision.whitespace
        && decision.directive_spacing.is_none()
    {
        return Ok(insert);
    }
    let mut replacement = decision.whitespace.clone();
    replacement.push_str(&spec.snapshot().text()[start + prefix_len..range.start]);
    replacement.push(ch);
    let mut end = range.end;
    if ch == '#'
        && let Some(spacing) = decision.directive_spacing
    {
        end += spacing.range.len();
        replacement.push_str(&spacing.insert);
    }
    let mut tx = Transaction::new(
        state.snapshot().version(),
        vec![Change::new(start..end, replacement.clone())],
    );
    tx.selection = Some(Selection::caret(start + replacement.len()));
    Ok(tx)
}
