use super::indent_rules::{
    AlignmentAnchor, IndentRule, IndentSegment, IndentSlot as S, OffsetRule, offset, rule,
};
use super::{
    CppRules, NodeKind as N, PPDirectiveIndent, SyntaxTree, TokenKind as K, column_width,
    lexer::{significant_after, significant_before, spanning},
    materialize,
};
use crate::core::{Change, EditError, Snapshot};

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
    /// A requires clause on its own line under template parameters.
    RequiresClause,
    /// A goto label, placed by IndentGotoLabels.
    GotoLabel,
    PreprocessorDirective,
    OpeningToken,
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
            leading(&self.snapshot.line(line).unwrap()),
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
    /// Where the body of the directive at `hash` goes, one level in from
    /// the line it starts on.
    fn slot_of_directive(&self, hash: usize) -> usize {
        let at = self.tree.tokens[hash].range.start;
        let base = self.indent(self.line_of(at));
        self.slot(
            IndentRole::PreprocessorDirective,
            S::PreprocessorBody,
            base,
            Some(at),
        )
        .target_column
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
                        // A line comment right after `{` stands for the first
                        // element unless the style breaks after the brace.
                        let first_comment =
                            slot == S::BracedInitializer && self.style.initializer.first_comment;
                        self.tree.tokens[self.tree.nodes[owner].tokens.start + 1
                            ..self.tree.nodes[owner].tokens.end]
                            .iter()
                            .find(|t| {
                                !t.kind.is_trivia() || (first_comment && t.kind == K::LineComment)
                            })
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
        // The block a case label opens, `case A:` above `{`, starts with it,
        // as clang-format's parseLabel has it: unless IndentCaseBlocks makes
        // it an ordinary statement, or comments on lines of their own come
        // between them.
        if node.kind == N::CompoundStatement
            && !self.style.structure.indent_case_blocks
            && let Some(parent) = node.parent
            && self.tree.nodes[parent].kind == N::CaseSection
            && let [label, block, ..] = self.tree.nodes[parent].children[..]
            && block == id
            && !own_line_comment(
                &self.tree.tokens[self.tree.nodes[label].tokens.end..node.tokens.start],
            )
        {
            return self.tree.range(parent).start;
        }
        self.tree.range(id).start
    }
    fn lambda_body(&self, id: usize) -> bool {
        self.tree.nodes[id].kind == N::CompoundStatement
            && (self.tree.nodes[id].parent.is_some_and(|parent| {
                matches!(
                    self.tree.nodes[parent].kind,
                    N::ParenGroup | N::BracketGroup | N::BraceGroup | N::OpaqueDeclaration
                )
            }) || self.requires_keyword(id).is_some())
    }
    /// How far the braces of block `id`, on lines of their own, stand in
    /// from where they would otherwise go: BreakBeforeBraces GNU and
    /// BraceWrapping.IndentBraces indent those of control statements, case
    /// blocks and lambdas; Whitesmiths those of every block but lambdas.
    fn brace_shift(&self, id: usize) -> usize {
        use super::BraceIndent;
        let mode = self.style.structure.brace_indent;
        let node = &self.tree.nodes[id];
        if mode == BraceIndent::None
            || !matches!(
                node.kind,
                N::CompoundStatement | N::NamespaceBody | N::ClassBody
            )
        {
            return 0;
        }
        let open = node.tokens.start;
        if self.tree.tokens.get(open).map(|t| t.kind) != Some(K::LBrace)
            || self.first(self.line_of(self.tree.tokens[open].range.start)) != Some(open)
            || self.requires_keyword(id).is_some()
        {
            return 0;
        }
        let lambda = node.kind == N::CompoundStatement
            && self.lambda_body(id)
            && self.lambda_introducer(open).is_some();
        let control = node.parent.is_some_and(|parent| {
            matches!(
                self.tree.nodes[parent].kind,
                N::IfStatement
                    | N::ElseClause
                    | N::ForStatement
                    | N::WhileStatement
                    | N::DoStatement
                    | N::SwitchStatement
                    | N::CaseSection
            )
        });
        let applies = match mode {
            BraceIndent::None => false,
            BraceIndent::Control => control || lambda,
            BraceIndent::All => !lambda,
        };
        if applies {
            self.style.whitespace.indent_width
        } else {
            0
        }
    }
    /// The move a block's indented braces give the lines inside it: GNU
    /// keeps the body a level in from the brace, Whitesmiths puts it under
    /// the brace, so a block standing alone moves back by the shift.
    fn body_shift(&self, id: usize) -> isize {
        use super::BraceIndent;
        let shift = self.brace_shift(id) as isize;
        match self.style.structure.brace_indent {
            BraceIndent::Control => shift,
            BraceIndent::All
                if self.origin(id) == self.tree.range(id).start && !self.lambda_body(id) =>
            {
                -shift
            }
            _ => 0,
        }
    }
    /// Where a body laid out like a lambda's, and its closing brace,
    /// measure from. A lambda whose brace begins its line, BraceWrapping's
    /// BeforeLambdaBody, measures from that line; a body that only looks
    /// like a lambda's, as that of `struct tm f()`, has its brace's column,
    /// which Whitesmiths indents, for its own.
    fn lambda_block_base(&self, id: usize) -> usize {
        let open = self.tree.nodes[id].tokens.start;
        if self.lambda_introducer(open).is_none() {
            return self.lambda_base(id).saturating_sub(self.brace_shift(id));
        }
        let line = self.line_of(self.tree.tokens[open].range.start);
        if self.first(line) == Some(open) {
            self.indent(line)
        } else {
            self.lambda_base(id)
        }
    }
    /// The `requires` of a requires expression whose body is `body`.
    fn requires_keyword(&self, body: usize) -> Option<usize> {
        let tokens = &self.tree.tokens;
        let open = self.tree.nodes[body].tokens.start;
        if tokens.get(open)?.kind != K::LBrace {
            return None;
        }
        let mut i = significant_before(tokens, tokens[open].range.start)?;
        if tokens[i].kind == K::RParen {
            let group = self.tree.nodes[self.tree.token_owner(i)].tokens.start;
            i = significant_before(tokens, tokens[group].range.start)?;
        }
        (tokens[i].kind == K::Identifier
            && self.tree.source()[tokens[i].range.clone()] == *"requires")
            .then_some(i)
    }
    /// The `[` introducing the lambda whose body opens at token `open`, and
    /// whether the lambda declares a trailing return type.
    fn lambda_introducer(&self, open: usize) -> Option<(usize, bool)> {
        let tokens = &self.tree.tokens;
        let mut at = tokens[open].range.start;
        let mut arrow = false;
        loop {
            let i = significant_before(tokens, at)?;
            match tokens[i].kind {
                K::RBracket => {
                    return Some((
                        self.tree.nodes[self.tree.token_owner(i)].tokens.start,
                        arrow,
                    ));
                }
                // Parameters and template arguments of the declarator.
                K::RParen | K::Greater => {
                    at = tokens[self.tree.nodes[self.tree.token_owner(i)].tokens.start]
                        .range
                        .start;
                }
                // Specifiers, trailing return types and their qualifiers.
                K::Identifier | K::ColonColon | K::Arrow | K::Amp | K::AmpAmp | K::Star => {
                    arrow |= tokens[i].kind == K::Arrow;
                    at = tokens[i].range.start;
                }
                _ => return None,
            }
        }
    }
    fn awaits_operand(&self, closer: usize) -> bool {
        let tokens = &self.tree.tokens;
        significant_before(tokens, tokens[closer].range.start).is_some_and(|before| {
            super::expression::awaits_operand(tokens[closer].kind, tokens[before].kind)
        })
    }
    /// clang-format's NestedBlockIndent for a lambda body (the Signature
    /// LambdaBodyIndentation): the body is one level deeper and the closing
    /// brace aligns with it.
    fn lambda_base(&self, body: usize) -> usize {
        // A requires expression: RequiresExpressionIndentation Keyword
        // measures from the keyword, OuterScope like a lambda's signature.
        if let Some(keyword) = self.requires_keyword(body) {
            let at = self.tree.tokens[keyword].range.start;
            if self.style.structure.requires_expression_keyword {
                return self.column(at);
            }
            let scope = self.tree.nodes[body].parent.unwrap();
            return if self.tree.nodes[scope].kind.is_group() {
                self.nested_block_indent(scope, keyword, false)
            } else {
                self.indent(self.line_of(at))
            };
        }
        // LambdaBodyIndentation: OuterScope measures from the line the
        // statement holding the lambda starts on, whatever its signature.
        if self.style.structure.lambda_outer_scope {
            let mut scope = self.tree.nodes[body].parent.unwrap();
            while self.tree.nodes[scope].kind.is_group()
                && let Some(parent) = self.tree.nodes[scope].parent
            {
                scope = parent;
            }
            return self.indent(self.line_of(self.tree.range(scope).start));
        }
        let open = self.tree.nodes[body].tokens.start;
        let (start, arrow) = self.lambda_introducer(open).unwrap_or((open, false));
        let scope = self.tree.nodes[body].parent.unwrap();
        self.nested_block_indent(scope, start, arrow)
    }
    /// NestedBlockIndent of `scope` on reaching token `until`. A line that
    /// starts at the scope's own level resets it to that line's column, or
    /// past a leading conditional operator; nested groups inherit it from
    /// their opener, and an if/for condition starts it after its parenthesis.
    fn nested_block_indent(&self, scope: usize, until: usize, arrow: bool) -> usize {
        let tokens = &self.tree.tokens;
        let node = &self.tree.nodes[scope];
        let opener = node.tokens.start;
        let group = node.kind.is_group();
        let mut indent = if !group {
            self.indent(self.line_of(tokens[opener].range.start))
        } else if node.kind == N::ParenGroup
            && self.condition_paren(opener)
            && let Some(first) = significant_after(tokens, tokens[opener].range.end)
        {
            self.column(tokens[first].range.start)
        } else {
            self.nested_block_indent(node.parent.unwrap(), opener, false)
        };
        let line_first = |i: usize| self.first(self.line_of(tokens[i].range.start)) == Some(i);
        // Tokens at this scope's level, including openers of its direct children.
        let level = |i: usize| {
            let owner = self.tree.token_owner(i);
            owner == scope
                || (self.tree.nodes[owner].parent == Some(scope)
                    && self.tree.nodes[owner].tokens.start == i)
        };
        let mut conditional = false;
        let scanned = tokens.iter().enumerate().take(until);
        for (i, token) in scanned.skip(opener + usize::from(group)) {
            if token.kind.is_trivia() || !level(i) {
                continue;
            }
            let ternary = token.kind == K::Question || (conditional && token.kind == K::Colon);
            conditional |= token.kind == K::Question;
            if line_first(i) && token.kind != K::Arrow {
                indent = self.column(token.range.start) + if ternary { 2 } else { 0 };
            }
        }
        // A wrapped lambda with a trailing return type at statement level is
        // laid out like a free-standing function.
        if line_first(until) && !(arrow && !group) {
            indent = self.column(tokens[until].range.start);
        }
        indent
    }
    fn condition_paren(&self, opener: usize) -> bool {
        let tokens = &self.tree.tokens;
        let Some(keyword) = significant_before(tokens, tokens[opener].range.start) else {
            return false;
        };
        match tokens[keyword].kind {
            K::IfKw | K::ForKw => true,
            K::Identifier if &self.tree.source[tokens[keyword].range.clone()] == "constexpr" => {
                significant_before(tokens, tokens[keyword].range.start)
                    .is_some_and(|i| tokens[i].kind == K::IfKw)
            }
            _ => false,
        }
    }
    /// The tokens of a line other than blanks, comments among them.
    fn line_tokens(&self, line: usize) -> Vec<usize> {
        let Some(r) = self.snapshot.line_content_range(line) else {
            return vec![];
        };
        let start = self
            .tree
            .tokens
            .partition_point(|t| t.range.start < r.start);
        (start..self.tree.tokens.len())
            .take_while(|&i| self.tree.tokens[i].range.start < r.end)
            .filter(|&i| {
                !matches!(
                    self.tree.tokens[i].kind,
                    K::Whitespace | K::Newline | K::EndOfFile
                )
            })
            .collect()
    }
    /// The line comment that ends `line` and a later comment can continue,
    /// with the column it stands at and the least column a continuation
    /// needs, as clang-format's continuesLineCommentSection has them: right
    /// of where the line starts, or of a `{` the comment follows; a comment
    /// that continues one is continued from its own column.
    fn comment_section(&self, line: usize) -> Option<(usize, usize)> {
        let tokens = self.line_tokens(line);
        let (&last, rest) = tokens.split_last()?;
        if self.tree.tokens[last].kind != K::LineComment {
            return None;
        }
        let column = self.column(self.tree.tokens[last].range.start);
        let Some(&first) = rest.first() else {
            // A comment alone on its line goes on only as a continuation,
            // which lines up with the section it continues.
            let (section, least) = self.comment_section(line.checked_sub(1)?)?;
            return (column >= least).then_some((section, column));
        };
        // A label, `case A: // note`, ends its line before the comment
        // under it, which then belongs to what the label introduces.
        if rest
            .last()
            .is_some_and(|&i| self.tree.tokens[i].kind == K::Colon)
        {
            return None;
        }
        let brace = rest
            .last()
            .filter(|&&i| self.tree.tokens[i].kind == K::LBrace)
            .copied();
        let least = self.column(self.tree.tokens[brace.unwrap_or(first)].range.start) + 1;
        Some((column, least))
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
        let start = self.snapshot.line_start(self.line).unwrap();
        if let Some(t) = spanning(&self.tree.tokens, start) {
            let role = match t.kind {
                K::RawStringLiteral => Some(IndentRole::PreservedRawString),
                K::BlockComment => Some(IndentRole::PreservedBlockComment),
                K::StringLiteral | K::CharacterLiteral => Some(IndentRole::PreservedString),
                _ => None,
            };
            if let Some(role) = role {
                let mut d = self.fixed(role, self.indent(self.line), Some(t.range.start));
                d.preserve = true;
                d.whitespace = leading(&self.snapshot.line(self.line).unwrap()).into();
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
                decision.whitespace = leading(&self.snapshot.line(self.line).unwrap()).into();
                return decision;
            }
            enclosing = self.tree.nodes[id].parent;
        }
        if !self.style.enabled {
            let mut d = self.fixed(IndentRole::Opaque, self.indent(self.line), None);
            d.preserve = true;
            d.whitespace = leading(&self.snapshot.line(self.line).unwrap()).into();
            return d;
        }
        let first = self.first(self.line);
        // A comment that continues the comment ending the line above, at a
        // column right of where that line starts, stays beside it.
        if let [only] = self.line_tokens(self.line)[..]
            && self.tree.tokens[only].kind == K::LineComment
            && let Some(above) = self.line.checked_sub(1)
            && let Some((column, least)) = self.comment_section(above)
            && self.column(self.tree.tokens[only].range.start) >= least
        {
            return self.fixed(IndentRole::StatementContinuation, column, None);
        }
        if let Some(i) = first {
            let token = &self.tree.tokens[i];
            let id = self.tree.token_owner(i);
            match self.tree.format_kind(i) {
                K::LBrace
                    if matches!(
                        self.tree.nodes[id].kind,
                        N::CompoundStatement | N::NamespaceBody | N::ClassBody
                    ) =>
                {
                    // A lambda's brace on its own line, BraceWrapping's
                    // BeforeLambdaBody, stands where its closing brace will.
                    // Among arguments it lines up with them, as clang-format
                    // gives a line that starts in parentheses their indent.
                    if self.tree.nodes[id].kind == N::CompoundStatement
                        && self.lambda_body(id)
                        && let Some((introducer, _)) = self.lambda_introducer(i)
                    {
                        let anchor = Some(self.tree.tokens[introducer].range.start);
                        let scope = self.tree.nodes[id].parent.unwrap();
                        let introducer_line =
                            self.line_of(self.tree.tokens[introducer].range.start);
                        // At statement level the brace goes where the
                        // statement starts; among arguments, where a lambda
                        // that starts its line does, or with the arguments.
                        let column = if !self.tree.nodes[scope].kind.is_group() {
                            self.indent(self.line_of(self.tree.range(scope).start))
                        } else if self.first(introducer_line) == Some(introducer) {
                            self.indent(introducer_line)
                        } else {
                            let base = self.indent(self.line_of(self.origin(scope)));
                            self.aligned_slot(
                                IndentRole::OpeningToken,
                                S::ParameterContinuation,
                                scope,
                                base,
                                anchor,
                            )
                            .target_column
                        };
                        return self.fixed(
                            IndentRole::OpeningToken,
                            column + self.brace_shift(id),
                            anchor,
                        );
                    }
                    let anchor = self.origin(id);
                    if self.line_of(anchor) < self.line {
                        return self.fixed(
                            IndentRole::OpeningToken,
                            self.indent(self.line_of(anchor)) + self.brace_shift(id),
                            Some(anchor),
                        );
                    }
                }
                K::RBrace | K::RParen | K::RBracket
                    if matches!(
                        self.tree.nodes[id].kind,
                        N::CompoundStatement
                            | N::BraceGroup
                            | N::NamespaceBody
                            | N::ClassBody
                            | N::ParenGroup
                            | N::BracketGroup
                    ) && !self.awaits_operand(i) =>
                {
                    let anchor = self.origin(id);
                    let column = if self.lambda_body(id) {
                        self.lambda_block_base(id)
                    } else {
                        self.indent(self.line_of(anchor))
                    };
                    // A block that stands alone has its brace as its origin.
                    let shift = if self.lambda_body(id) || anchor == self.tree.range(id).start {
                        0
                    } else {
                        self.brace_shift(id)
                    };
                    return self.fixed(IndentRole::ClosingToken, column + shift, Some(anchor));
                }
                // `requires` under `template<...>`, or after a declarator:
                // one level in from the declaration with
                // IndentRequiresClause, else beside it.
                K::Identifier
                    if self.tree.source()[token.range.clone()] == *"requires"
                        && ((self.tree.nodes[id].kind == N::OpaqueDeclaration
                            && self.tree.tokens[self.tree.nodes[id].tokens.start].kind
                                == K::TemplateKw)
                            || (matches!(
                                self.tree.nodes[id].kind,
                                N::OpaqueDeclaration | N::FunctionDefinition
                            ) && significant_before(&self.tree.tokens, token.range.start)
                                .is_some_and(|before| {
                                    before >= self.tree.nodes[id].tokens.start
                                        && matches!(
                                            self.tree.tokens[before].kind,
                                            K::RParen | K::Identifier | K::Greater | K::RBracket
                                        )
                                }))) =>
                {
                    let anchor = self.tree.range(id).start;
                    let base = self.indent(self.line_of(anchor));
                    let column = base
                        + if self.style.structure.indent_requires_clause {
                            self.style.whitespace.indent_width
                        } else {
                            0
                        };
                    return self.fixed(IndentRole::RequiresClause, column, Some(anchor));
                }
                K::PreprocessorHash => {
                    if self.style.directive.layout == PPDirectiveIndent::Leave {
                        let mut decision = self.fixed(
                            IndentRole::PreprocessorDirective,
                            self.indent(self.line),
                            None,
                        );
                        decision.preserve = true;
                        decision.whitespace =
                            leading(&self.snapshot.line(self.line).unwrap()).into();
                        return decision;
                    }
                    let level = self.pp_level();
                    let depth = level * self.style.directive.width;
                    let structural = level * self.style.whitespace.indent_width;
                    let mut decision =
                        if self.style.directive.layout == PPDirectiveIndent::BeforeHash {
                            self.decision(
                                IndentRole::PreprocessorDirective,
                                structural,
                                depth,
                                depth,
                                None,
                            )
                        } else {
                            self.fixed(IndentRole::PreprocessorDirective, 0, None)
                        };
                    {
                        let start = token.range.end;
                        let len = leading(&self.snapshot.text()[start..]).len();
                        // LLVM gives indentation after # a zero-based tab origin.
                        let target = if self.style.directive.layout == PPDirectiveIndent::AfterHash
                        {
                            depth
                        } else {
                            0
                        };
                        let spaces =
                            materialize(structural, target, target, &self.style.whitespace);
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
                        let shift = self.tree.nodes[switch]
                            .children
                            .iter()
                            .find(|&&child| self.tree.nodes[child].kind == N::CompoundStatement)
                            .map_or(0, |&body| self.body_shift(body));
                        return self.slot(
                            IndentRole::CaseLabel,
                            S::CaseLabel,
                            self.indent(self.line_of(anchor))
                                .saturating_add_signed(shift),
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
            let content = self.snapshot.line(self.line).unwrap();
            let line = content.trim_start();
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
            let prev = significant_before(&self.tree.tokens, query).map(|i| &self.tree.tokens[i]);
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
        let base = self
            .indent(self.line_of(anchor))
            .saturating_add_signed(self.body_shift(id));
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
                // `export {`, not `export namespace`.
                let export = node.parent.is_some_and(|parent| {
                    let first = self.tree.nodes[parent].tokens.start;
                    &self.tree.source()[self.tree.tokens[first].range.clone()] == "export"
                        && self.tree.tokens[first + 1..node.tokens.start]
                            .iter()
                            .all(|t| t.kind.is_trivia())
                });
                let slot = match (is_extern, nested) {
                    _ if export => S::ExportBody,
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
                let (role, base) = match parent {
                    _ if self.lambda_body(id) => {
                        (IndentRole::LambdaBody, self.lambda_block_base(id))
                    }
                    Some(N::FunctionDefinition) => (IndentRole::FunctionBody, base),
                    _ => (IndentRole::CompoundBody, base),
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
                } else if self.after_attributes(id) {
                    fixed(IndentRole::Opaque, base)
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
            // After the body of a `do` comes its `while`.
            N::DoStatement
                if first.is_some_and(|i| self.tree.tokens[i].kind == K::WhileKw)
                    || node.children.iter().any(|&child| {
                        self.tree.nodes[child].kind != N::ParenGroup
                            && !self.tree.nodes[child].incomplete
                            && self.tree.range(child).end <= query
                    }) =>
            {
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
            _ if self.after_attributes(id) => fixed(IndentRole::Opaque, base),
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
    /// Whether only attributes, `[[nodiscard]]` on lines of their own, come
    /// before the line in its declaration: the declaration starts there.
    fn after_attributes(&self, id: usize) -> bool {
        let node = &self.tree.nodes[id];
        if !matches!(node.kind, N::FunctionDefinition | N::OpaqueDeclaration) {
            return false;
        }
        let tokens = &self.tree.tokens;
        let mut i = node.tokens.start;
        let mut seen = false;
        while i < node.tokens.end && self.line_of(tokens[i].range.start) < self.line {
            match node
                .children
                .iter()
                .find(|&&c| self.tree.nodes[c].tokens.start == i)
            {
                Some(&c) if self.tree.nodes[c].kind == N::BracketGroup => {
                    i = self.tree.nodes[c].tokens.end;
                    seen = true;
                }
                _ if tokens[i].kind.is_trivia() => i += 1,
                _ => return false,
            }
        }
        seen
    }
    /// Whether the line starts the name of a function declared at file,
    /// namespace or class scope after its return type, like clang-format's
    /// TT_FunctionDeclarationName. A variable's name wrapped after its type
    /// continues the declaration instead.
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
        let tokens = &self.tree.tokens;
        let child_at = |i: usize| {
            node.children
                .iter()
                .copied()
                .find(|&c| self.tree.nodes[c].tokens.start == i)
        };
        let Some(first) = node.tokens.clone().find(|&i| {
            !tokens[i].kind.is_trivia() && self.line_of(tokens[i].range.start) == self.line
        }) else {
            return false;
        };
        // The type ends just before the line.
        let Some(before) = (node.tokens.start..first)
            .rev()
            .find(|&i| !tokens[i].kind.is_trivia())
        else {
            return false;
        };
        // clang-format keeps an `operator` name with its class, `A::\noperator T()`.
        if !matches!(
            tokens[before].kind,
            K::Identifier | K::Greater | K::GreaterGreater | K::Star | K::Amp | K::AmpAmp
        ) && !(tokens[before].kind == K::ColonColon && tokens[first].kind == K::OperatorKw)
        {
            return false;
        }
        // The name runs from the line to the parameters.
        let mut prev = K::EndOfFile;
        let mut i = first;
        let params = loop {
            if i >= node.tokens.end {
                return false;
            }
            if let Some(child) = child_at(i) {
                match self.tree.nodes[child].kind {
                    N::ParenGroup if prev == K::OperatorKw => prev = K::RParen,
                    N::ParenGroup => break child,
                    N::TemplateArgumentList => prev = K::Greater,
                    _ => return false,
                }
                i = self.tree.nodes[child].tokens.end;
                continue;
            }
            let k = tokens[i].kind;
            i += 1;
            if k.is_trivia() {
                continue;
            }
            if !matches!(k, K::Identifier | K::ColonColon | K::OperatorKw | K::Tilde)
                && prev != K::OperatorKw
            {
                return false;
            }
            prev = k;
        };
        node.kind == N::FunctionDefinition
            || node
                .children
                .iter()
                .any(|&c| self.tree.nodes[c].kind == N::CompoundStatement)
            || self.declares_function(id, params)
    }
    /// clang-format's isFunctionDeclarationName for a declaration without a
    /// body: the parameters hold declarations rather than arguments.
    fn declares_function(&self, id: usize, params: usize) -> bool {
        let tokens = &self.tree.tokens;
        let group = &self.tree.nodes[params];
        let significant =
            |range: std::ops::Range<usize>| range.filter(|&i| !tokens[i].kind.is_trivia());
        let inner = group.tokens.start + 1..group.tokens.end.saturating_sub(1);
        let Some(head) = significant(inner.clone()).next() else {
            return true;
        };
        if significant(group.tokens.end..self.tree.nodes[id].tokens.end)
            .next()
            .is_some_and(|i| {
                matches!(tokens[i].kind, K::Amp | K::AmpAmp | K::Arrow)
                    || matches!(
                        self.snapshot.text().get(tokens[i].range.clone()),
                        Some("const" | "noexcept" | "override" | "final" | "volatile")
                    )
            })
        {
            return true;
        }
        let ends_with_semicolon = significant(self.tree.nodes[id].tokens.clone())
            .next_back()
            .is_some_and(|i| tokens[i].kind == K::Semicolon);
        if tokens[head].kind == K::Identifier && !ends_with_semicolon {
            return true;
        }
        let mut prev = K::EndOfFile;
        let mut i = inner.start;
        while i < inner.end {
            if let Some(&child) = group
                .children
                .iter()
                .find(|&&c| self.tree.nodes[c].tokens.start == i)
            {
                i = self.tree.nodes[child].tokens.end;
                prev = K::Greater;
                continue;
            }
            let k = tokens[i].kind;
            i += 1;
            if k.is_trivia() {
                continue;
            }
            let text = self
                .snapshot
                .text()
                .get(tokens[i - 1].range.clone())
                .unwrap_or("");
            let named = matches!(
                prev,
                K::Identifier | K::Greater | K::Star | K::Amp | K::AmpAmp
            );
            match k {
                K::Ellipsis => return true,
                K::Identifier
                    if matches!(
                        text,
                        "const"
                            | "void"
                            | "bool"
                            | "char"
                            | "short"
                            | "int"
                            | "long"
                            | "float"
                            | "double"
                            | "signed"
                            | "unsigned"
                            | "auto"
                            | "wchar_t"
                            | "char8_t"
                            | "char16_t"
                            | "char32_t"
                    ) =>
                {
                    return true;
                }
                K::Identifier if named => return true,
                K::Star | K::Amp | K::AmpAmp if named => return true,
                K::LBrace
                | K::Number
                | K::StringLiteral
                | K::RawStringLiteral
                | K::CharacterLiteral => return false,
                _ => {}
            }
            prev = k;
        }
        false
    }
    fn pp_level(&self) -> usize {
        if self.style.directive.layout == PPDirectiveIndent::None {
            return 0;
        }
        let guard = super::preprocessor::include_guard(self.snapshot.text(), &self.tree.tokens);
        let mut level = 0usize;
        for (hash, token) in self
            .tree
            .tokens
            .iter()
            .enumerate()
            .filter(|(_, t)| t.kind == K::PreprocessorHash && t.preprocessor)
        {
            let word = super::preprocessor::keyword(self.snapshot.text(), &self.tree.tokens, hash)
                .unwrap_or("");
            let own = match word {
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
            if self.line_of(token.range.start) == self.line {
                return own.saturating_sub(usize::from(guard));
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
    let computer = Computer {
        snapshot,
        tree,
        line,
        style,
    };
    let decision = computer.run();
    // A block standing alone among statements, its brace indented.
    if !decision.preserve
        && decision.role != IndentRole::OpeningToken
        && let Some(open) = computer.first(line)
        && tree.tokens()[open].kind == K::LBrace
    {
        let block = tree.token_owner(open);
        if tree.nodes()[block].tokens.start == open
            && computer.origin(block) == tree.tokens()[open].range.start
        {
            let shift = computer.brace_shift(block);
            if shift > 0 {
                return Ok(computer.fixed(
                    IndentRole::OpeningToken,
                    decision.target_column + shift,
                    decision.anchor,
                ));
            }
        }
    }
    // Comments on lines of their own go with the line after them, such a
    // brace among it.
    if !decision.preserve
        && computer.first(line).is_none()
        && let Some(range) = snapshot.line_content_range(line)
        && let Some(comment) = tree
            .tokens()
            .iter()
            .position(|t| t.range.start >= range.start && t.kind != K::Whitespace)
        && matches!(
            tree.tokens()[comment].kind,
            K::LineComment | K::BlockComment
        )
        && let Some(open) = super::lexer::significant_after(tree.tokens(), range.start)
        && tree.tokens()[open].kind == K::LBrace
        && computer.first(computer.line_of(tree.tokens()[open].range.start)) == Some(open)
    {
        let block = tree.token_owner(open);
        if tree.nodes()[block].tokens.start == open
            && computer.origin(block) == tree.tokens()[open].range.start
        {
            let shift = computer.brace_shift(block);
            if shift > 0 {
                let mut shifted = computer.fixed(
                    decision.role,
                    decision.target_column + shift,
                    decision.anchor,
                );
                shifted.fallback = decision.fallback;
                return Ok(shifted);
            }
        }
    }
    if !decision.preserve
        && let Some(body) = macro_body(snapshot, tree, line, style)
    {
        return Ok(body);
    }
    if !decision.preserve && goto_label(snapshot, tree, line) {
        // Placed against the statements the label stands among.
        let statements = decision.target_column;
        let width = style.whitespace.indent_width;
        let column = match style.structure.goto_labels {
            super::GotoLabelIndent::None => 0,
            super::GotoLabelIndent::Outer => statements.saturating_sub(width),
            super::GotoLabelIndent::Inner => statements,
            super::GotoLabelIndent::Half => statements.saturating_sub(width / 2),
        };
        return Ok(computer.fixed(IndentRole::GotoLabel, column, None));
    }
    Ok(decision)
}

/// Whether `line` is a goto label: a name and a colon that make a statement
/// of their own.
fn goto_label(snapshot: &Snapshot, tree: &SyntaxTree, line: usize) -> bool {
    let Some(range) = snapshot.line_content_range(line) else {
        return false;
    };
    let tokens = tree.tokens();
    let start = tokens.partition_point(|t| t.range.start < range.start);
    let mut significant = (start..tokens.len()).filter(|&i| !tokens[i].kind.is_trivia());
    let (Some(name), Some(colon)) = (significant.next(), significant.next()) else {
        return false;
    };
    if tokens[name].kind != K::Identifier || tokens[colon].kind != K::Colon {
        return false;
    }
    let owner = tree.token_owner(name);
    let node = &tree.nodes[owner];
    node.kind == N::OpaqueDeclaration
        && node.tokens.start <= name
        && (node.tokens.start..node.tokens.end)
            .filter(|&i| !tokens[i].kind.is_trivia())
            .eq([name, colon])
}

/// Whether a comment among `tokens` starts its line, rather than trailing
/// code on it.
fn own_line_comment(tokens: &[super::Token]) -> bool {
    let mut line_start = false;
    tokens.iter().any(|token| match token.kind {
        K::Newline => {
            line_start = true;
            false
        }
        K::Whitespace => false,
        K::LineComment | K::BlockComment if line_start => true,
        _ => {
            line_start = false;
            false
        }
    })
}

/// A continuation line of a directive, laid out as clang-format lays it out.
/// The replacement of a `#define` is code one level in: it is taken out
/// with its columns, inside a block whose contents start where the body does,
/// and indented as that code, unfinished as it may be while it is typed. The
/// expression of `#if` and the others is a statement that starts at the `#`.
fn macro_body(
    snapshot: &Snapshot,
    tree: &SyntaxTree,
    line: usize,
    style: &CppRules,
) -> Option<IndentDecision> {
    let tokens = tree.tokens();
    let source = tree.source();
    let start = snapshot.line_start(line)?;
    // The end of input is an empty token, which a line at the end gets.
    let first = tokens
        .partition_point(|t| t.range.end <= start)
        .min(tokens.len().saturating_sub(1));
    // A line after a backslash belongs to the directive even while it is
    // empty, as on Enter after `\`; the directive then ends on it.
    let continues = line > 0
        && snapshot
            .line(line - 1)?
            .trim_end_matches(['\n', '\r'])
            .ends_with('\\');
    if !tokens.get(first)?.preprocessor && !continues {
        return None;
    }
    let hash = tokens[..first]
        .iter()
        .rposition(|t| t.kind == K::PreprocessorHash && t.preprocessor)?;
    let end = super::preprocessor::directive_end(tokens, hash);
    if end < first || (end == first && !continues) {
        return None;
    }
    let define = super::preprocessor::keyword(source, tokens, hash) == Some("define");
    // SkipMacroDefinitionBody leaves the lines of a definition as they are.
    if define
        && style.structure.skip_macro_definition_body
        && line > snapshot.line_of(tokens[hash].range.start)?
    {
        let computer = Computer {
            snapshot,
            tree,
            line,
            style,
        };
        let mut decision = computer.fixed(
            IndentRole::PreservedMacro,
            computer.indent(line),
            Some(tokens[hash].range.start),
        );
        decision.preserve = true;
        decision.whitespace = leading(&snapshot.line(line)?).into();
        return Some(decision);
    }
    let significant = |from: usize| (from..end).find(|&i| !tokens[i].kind.is_trivia());
    let keyword = significant(hash + 1)?;
    // Other directives, `#if A && \` above all, continue an expression.
    let name = if define {
        significant(keyword + 1)?
    } else {
        keyword
    };
    let mut body = name + 1;
    let computer = Computer {
        snapshot,
        tree,
        line,
        style,
    };
    // A function-like macro's parameters touch its name.
    if define
        && tokens
            .get(body)
            .is_some_and(|t| t.kind == K::LParen && t.range.start == tokens[name].range.end)
    {
        let open = body;
        let mut depth = 0;
        let mut closed = false;
        while body < end {
            match tokens[body].kind {
                K::LParen => depth += 1,
                K::RParen => depth -= 1,
                _ => {}
            }
            body += 1;
            if depth == 0 {
                closed = true;
                break;
            }
        }
        // A wrapped parameter lines up with the first, or continues the
        // `#define` line.
        let open_line = snapshot.line_of(tokens[open].range.start)?;
        let close_line = if closed {
            snapshot.line_of(tokens[body - 1].range.start)?
        } else {
            usize::MAX
        };
        if line > open_line && line <= close_line {
            let column = significant(open + 1)
                .filter(|&i| {
                    style.expression.align_parentheses
                        && snapshot.line_of(tokens[i].range.start) == Some(open_line)
                })
                .map_or_else(
                    || computer.indent(open_line) + style.expression.continuation_width,
                    |i| computer.column(tokens[i].range.start),
                );
            return Some(computer.fixed(
                IndentRole::ParenContinuation,
                column,
                Some(tokens[open].range.start),
            ));
        }
    }
    let body_start = tokens
        .get(body)
        .map_or(tokens[end - 1].range.end, |t| t.range.start);
    // Where a body line goes when nothing is known of the code: one level
    // in from the directive, as the analysis of the whole file has it. The
    // expression of another directive is a statement where the `#` is.
    let base = if define {
        computer.slot_of_directive(hash)
    } else {
        computer.indent(snapshot.line_of(tokens[hash].range.start)?)
    };
    let first_line = snapshot.line_of(tokens[hash].range.start)?;
    let last_line = snapshot
        .line_of(
            tokens[end - 1]
                .range
                .end
                .saturating_sub(1)
                .max(tokens[hash].range.start),
        )?
        .max(line);
    let tab = style.whitespace.tab_width;
    let width = style.whitespace.indent_width;
    // Contents of the block start at `base`; its brace stands a level out.
    let mut text = String::new();
    if define {
        text.push_str(&" ".repeat(base.saturating_sub(width)));
        text.push_str("{\n");
    }
    for number in first_line..=last_line {
        let content = snapshot.line(number)?;
        let content = content.trim_end_matches(['\n', '\r']);
        let content = content.strip_suffix('\\').unwrap_or(content);
        let line_start = snapshot.line_start(number)?;
        if number != first_line && line_start < body_start {
            // Parameters wrapped onto this line are part of the header.
            let header = (body_start - line_start).min(content.len());
            text.push_str(&" ".repeat(column_width(&content[..header], 0, tab)));
            text.push_str(&content[header..]);
        } else if number == first_line {
            // The header gives way to blanks as wide, so that what follows
            // it keeps its column. The expression of `#if` starts where the
            // `#` does, as clang-format lays it out: `0 +` stands for the
            // header, binding tighter than any operator it could meet.
            let header = body_start.saturating_sub(line_start).min(content.len());
            let blank = column_width(&content[..header], 0, tab);
            if define || blank < 3 {
                text.push_str(&" ".repeat(blank));
            } else {
                text.push_str("0 +");
                text.push_str(&" ".repeat(blank - 3));
            }
            text.push_str(&content[header..]);
        } else {
            text.push_str(content);
        }
        text.push('\n');
    }
    // Macros leave out the final semicolon, `do { ... } while (0)` above
    // all; one on a line of its own completes the code and moves nothing.
    text.push_str(";\n");
    if define {
        text.push_str(&" ".repeat(base.saturating_sub(width)));
        text.push_str("}\n");
    }
    let inner = super::parse_with_options(&text, &style.parser);
    let inner_snapshot = Snapshot::new(text, 0);
    let inner_line = line - first_line + usize::from(define);
    let mut decision = compute_indent(&inner_snapshot, &inner, inner_line, style).ok()?;
    if decision.preserve {
        return None;
    }
    decision.anchor = None;
    decision.directive_spacing = None;
    Some(decision)
}
