use super::{
    Node, NodeKind as N, ParserOptions, SyntaxTree, TokenKind as K, lex, lexer::significant_after,
};
use crate::core::Snapshot;
use std::sync::Arc;

const MAX_NESTING: usize = 128;
const TEMPLATE_LOOKAHEAD: usize = 200;

pub fn parse(source: &str) -> SyntaxTree {
    parse_with_options(source, &ParserOptions::default())
}

pub fn parse_snapshot(snapshot: &Snapshot) -> SyntaxTree {
    parse_snapshot_with_options(snapshot, &ParserOptions::default())
}

pub fn parse_with_options(source: &str, options: &ParserOptions) -> SyntaxTree {
    parse_shared(source.into(), options)
}
pub fn parse_snapshot_with_options(snapshot: &Snapshot, options: &ParserOptions) -> SyntaxTree {
    parse_shared(snapshot.shared_text(), options)
}
fn parse_shared(source: Arc<str>, options: &ParserOptions) -> SyntaxTree {
    let tokens = lex(&source);
    parse_tokens(source, options, tokens)
}
fn parse_tokens(
    source: Arc<str>,
    options: &ParserOptions,
    tokens: Vec<super::Token>,
) -> SyntaxTree {
    let mut p = Parser::new(source, options, tokens);
    p.open(N::TranslationUnit);
    p.tree.nodes[0].tokens.start = 0;
    p.items(false);
    p.tree.nodes[0].tokens.end = p.tree.tokens.len();
    p.tree.index_tokens();
    p.tree
}

#[path = "container.rs"]
mod container;
#[path = "incremental.rs"]
mod incremental;
pub(super) use incremental::reparse;
pub use incremental::{AnalysisFallback, AnalysisWork, ParseStrategy};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DirectiveKind {
    Other,
    ConditionalStart,
    ConditionalBranch,
    ConditionalEnd,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DirectiveStep {
    Unhandled,
    Consumed,
    LeaveScope,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LinkageHead {
    Other,
    Extern,
    ExternString,
}

#[derive(Clone, Copy)]
struct PPFrame {
    depth: usize,
    braces: usize,
}
#[derive(Clone, Copy)]
struct ReopenedScope {
    depth: usize,
    branch_depth: usize,
}
struct Parser {
    tree: SyntaxTree,
    pos: usize,
    stack: Vec<usize>,
    enum_body: bool,
    pp: Vec<PPFrame>,
    phantoms: Vec<ReopenedScope>,
    unwind: Option<usize>,
}
impl Parser {
    fn new(source: Arc<str>, options: &ParserOptions, tokens: Vec<super::Token>) -> Self {
        let macro_blocks = super::macros::classify(&source, &tokens, options);
        Self {
            tree: SyntaxTree {
                tokens,
                parser_options: options.clone(),
                source,
                nodes: vec![],
                token_owners: vec![],
                macro_blocks,
            },
            pos: 0,
            stack: vec![],
            enum_body: false,
            pp: vec![],
            phantoms: vec![],
            unwind: None,
        }
    }

    fn skip(&mut self) {
        while self.tree.tokens[self.pos].kind.is_trivia() {
            self.pos += 1;
        }
    }
    fn kind(&mut self) -> K {
        self.skip();
        self.tree.macro_blocks[self.pos]
            .map_or(self.tree.tokens[self.pos].kind, |block| block.kind())
    }
    fn at(&mut self, k: K) -> bool {
        self.kind() == k
    }
    fn advance(&mut self) {
        self.skip();
        if !self.at(K::EndOfFile) {
            self.pos += 1;
        }
    }
    fn text(&self, i: usize) -> &str {
        &self.tree.source[self.tree.tokens[i].range.clone()]
    }
    fn open(&mut self, kind: N) -> usize {
        self.skip();
        self.open_at_cursor(kind)
    }
    fn open_at_cursor(&mut self, kind: N) -> usize {
        let id = self.tree.nodes.len();
        let parent = self.stack.last().copied();
        self.tree.nodes.push(Node {
            kind,
            tokens: self.pos..self.pos,
            parent,
            children: vec![],
            incomplete: false,
            reclassified: false,
            whitespace_sensitive: false,
            extern_linkage: false,
            expected: None,
        });
        if let Some(parent) = parent {
            self.tree.nodes[parent].children.push(id);
        }
        self.stack.push(id);
        id
    }
    fn close(&mut self, id: usize) {
        let node = &self.tree.nodes[id];
        let floor = node
            .children
            .last()
            .map(|&c| self.tree.nodes[c].tokens.end)
            .unwrap_or(node.tokens.start);
        let mut end = self.pos;
        while end > floor && self.tree.tokens[end - 1].kind.is_trivia() {
            end -= 1;
        }
        self.tree.nodes[id].tokens.end = end;
        assert_eq!(self.stack.pop(), Some(id));
    }
    fn incomplete(&mut self, id: usize) {
        self.tree.nodes[id].incomplete = true;
    }
    fn missing(&mut self, expected: K) {
        self.skip();
        self.missing_at_cursor(expected);
    }
    fn missing_at_cursor(&mut self, expected: K) {
        let id = self.open_at_cursor(N::MissingToken);
        self.tree.nodes[id].expected = Some(expected);
        self.incomplete(id);
        self.close(id);
        if let Some(&parent) = self.stack.last() {
            self.incomplete(parent);
        }
    }
    fn expect(&mut self, k: K) {
        if self.at(k) {
            self.advance();
        } else {
            self.missing(k);
        }
    }
    fn guarded(&mut self) {
        self.skip();
        let before = self.pos;
        // Bounded nesting protects the editor from adversarial input. The
        // fallback consumes a token without manufacturing source text.
        if self.stack.len() < MAX_NESTING {
            self.item();
        }
        if before == self.pos {
            let id = self.open(N::Error);
            self.advance();
            self.close(id);
        }
    }
    fn items(&mut self, case: bool) {
        loop {
            let k = self.kind();
            if k == K::EndOfFile
                || (k == K::RBrace && self.stack.len() > 1)
                || (case && matches!(k, K::CaseKw | K::DefaultKw))
            {
                break;
            }
            match self.pp_item() {
                DirectiveStep::Consumed => continue,
                DirectiveStep::LeaveScope => break,
                _ => {}
            }
            self.guarded();
            if let Some(depth) = self.unwind {
                if self.stack.len() > depth {
                    break;
                }
                self.unwind = None;
            }
        }
    }
    fn item(&mut self) {
        let kind = self.kind();
        if let Some(block) = self.tree.macro_blocks[self.pos]
            && block != super::macros::BlockMacro::Close
        {
            self.macro_body(block);
            return;
        }
        if kind == K::Identifier {
            let name = self.text(self.pos);
            let control = if self
                .tree
                .parser_options
                .loop_macros
                .iter()
                .any(|s| s == name)
            {
                Some(K::ForKw)
            } else if self
                .tree
                .parser_options
                .conditional_macros
                .iter()
                .any(|s| s == name)
            {
                Some(K::IfKw)
            } else {
                None
            };
            if let Some(control) = control {
                self.control(control);
                return;
            }
            if self
                .tree
                .parser_options
                .namespace_macros
                .iter()
                .any(|s| s == name)
            {
                self.namespace_macro();
                return;
            }
        }
        match kind {
            K::PreprocessorHash => self.directive(),
            K::NamespaceKw => self.namespace(),
            K::ClassKw | K::StructKw | K::EnumKw | K::UnionKw => self.class(),
            K::PublicKw | K::ProtectedKw | K::PrivateKw => {
                let id = self.open(N::AccessSpecifierLabel);
                self.advance();
                while self.at(K::Identifier) {
                    self.advance();
                }
                self.expect(K::Colon);
                self.close(id);
            }
            K::TemplateKw => {
                let id = self.open(N::OpaqueDeclaration);
                self.advance();
                if self.at(K::Less) && !self.template_args() {
                    self.advance();
                }
                self.requires_clause();
                self.close(id);
            }
            k @ (K::IfKw | K::ForKw | K::WhileKw | K::DoKw | K::SwitchKw) => self.control(k),
            K::CaseKw | K::DefaultKw => self.case(),
            K::LBrace => self.body(N::CompoundStatement),
            K::Semicolon => {
                let id = self.open(N::OpaqueDeclaration);
                self.advance();
                self.close(id);
            }
            K::RBrace | K::EndOfFile => {}
            _ => self.generic(),
        }
    }
    fn line_start(&self) -> bool {
        for t in self.tree.tokens[..self.pos].iter().rev() {
            if t.kind == K::Newline {
                return true;
            }
            if !t.kind.is_trivia() {
                return false;
            }
        }
        true
    }
    fn newline_ahead(&self) -> bool {
        for t in &self.tree.tokens[self.pos..] {
            if matches!(t.kind, K::Newline | K::EndOfFile) {
                return true;
            }
            if !t.kind.is_trivia() {
                return false;
            }
        }
        true
    }
    fn delimiter(opener: K) -> (N, K) {
        match opener {
            K::LParen => (N::ParenGroup, K::RParen),
            K::LBracket => (N::BracketGroup, K::RBracket),
            K::LBrace => (N::BraceGroup, K::RBrace),
            _ => unreachable!("group requires an opening delimiter"),
        }
    }
    fn suffix(k: K) -> bool {
        matches!(
            k,
            K::Identifier | K::ColonColon | K::Arrow | K::Amp | K::AmpAmp | K::Star
        )
    }
    fn directive(&mut self) {
        let id = self.open(N::PreprocessorDirective);
        while self.pos + 1 < self.tree.tokens.len()
            && self.tree.tokens[self.pos].preprocessor
            && self.tree.tokens[self.pos].kind != K::Newline
        {
            let k = self.tree.tokens[self.pos].kind;
            if matches!(k, K::LParen | K::LBracket | K::LBrace) {
                self.pp_group(k);
            } else {
                self.pos += 1;
            }
        }
        self.close(id);
    }
    fn pp_group(&mut self, k: K) {
        let (n, closer) = Self::delimiter(k);
        let id = self.open(n);
        self.pos += 1;
        while self.pos + 1 < self.tree.tokens.len()
            && self.tree.tokens[self.pos].preprocessor
            && self.tree.tokens[self.pos].kind != K::Newline
        {
            let k = self.tree.tokens[self.pos].kind;
            if k == closer {
                self.pos += 1;
                self.close(id);
                return;
            }
            if matches!(k, K::LParen | K::LBracket | K::LBrace) && self.stack.len() < MAX_NESTING {
                self.pp_group(k);
            } else {
                self.pos += 1;
            }
        }
        self.missing_at_cursor(closer);
        self.close(id);
    }
    fn pp_category(&self, hash: usize) -> DirectiveKind {
        match super::preprocessor::keyword(&self.tree.source, &self.tree.tokens, hash) {
            Some("if" | "ifdef" | "ifndef") => DirectiveKind::ConditionalStart,
            Some("else" | "elif" | "elifdef" | "elifndef") => DirectiveKind::ConditionalBranch,
            Some("endif") => DirectiveKind::ConditionalEnd,
            _ => DirectiveKind::Other,
        }
    }
    fn braces(&self) -> usize {
        self.stack
            .iter()
            .filter(|&&id| {
                matches!(
                    self.tree.nodes[id].kind,
                    N::CompoundStatement | N::NamespaceBody | N::ClassBody | N::PPReopenedScope
                )
            })
            .count()
    }
    fn pp_item(&mut self) -> DirectiveStep {
        if !self.at(K::PreprocessorHash) {
            return DirectiveStep::Unhandled;
        }
        let depth = self.stack.len();
        match self.pp_category(self.pos) {
            DirectiveKind::ConditionalStart => {
                self.directive();
                self.pp.push(PPFrame {
                    depth,
                    braces: self.braces(),
                });
                DirectiveStep::Consumed
            }
            DirectiveKind::ConditionalBranch => {
                let Some(frame) = self.pp.last().copied() else {
                    return DirectiveStep::Unhandled;
                };
                if frame.depth < depth {
                    self.unwind = Some(frame.depth);
                    return DirectiveStep::LeaveScope;
                }
                self.unwind = None;
                self.directive();
                if frame.braces > self.braces() {
                    self.reopen(frame.braces - self.braces());
                }
                DirectiveStep::Consumed
            }
            DirectiveKind::ConditionalEnd => {
                if let Some(scope) = self.phantoms.last()
                    && self.pp.len() <= scope.branch_depth
                {
                    self.unwind = Some(scope.depth);
                    return DirectiveStep::LeaveScope;
                }
                self.pp.pop();
                self.directive();
                DirectiveStep::Consumed
            }
            _ => DirectiveStep::Unhandled,
        }
    }
    fn reopen(&mut self, count: usize) {
        if self.stack.len() >= MAX_NESTING {
            return;
        }
        let id = self.open(N::PPReopenedScope);
        let frames = self.pp.len();
        self.phantoms.push(ReopenedScope {
            depth: self.stack.len(),
            branch_depth: frames,
        });
        if count > 1 {
            self.reopen(count - 1);
        }
        loop {
            let k = self.kind();
            if matches!(k, K::EndOfFile | K::RBrace)
                || (k == K::PreprocessorHash
                    && self.pp.len() <= frames
                    && matches!(
                        self.pp_category(self.pos),
                        DirectiveKind::ConditionalBranch | DirectiveKind::ConditionalEnd
                    ))
            {
                break;
            }
            match self.pp_item() {
                DirectiveStep::Consumed => continue,
                DirectiveStep::LeaveScope => break,
                _ => self.guarded(),
            }
            if let Some(depth) = self.unwind {
                if self.stack.len() > depth {
                    break;
                }
                self.unwind = None;
            }
        }
        self.expect(K::RBrace);
        self.phantoms.pop();
        self.close(id);
    }
    fn body(&mut self, kind: N) {
        let id = self.open(kind);
        self.advance();
        self.items(false);
        self.expect(K::RBrace);
        self.close(id);
    }
    fn macro_body(&mut self, block: super::macros::BlockMacro) {
        use super::macros::BlockMacro;
        let declaration = matches!(block, BlockMacro::Namespace | BlockMacro::Extern).then(|| {
            let id = self.open(N::NamespaceDecl);
            self.tree.nodes[id].extern_linkage = block == BlockMacro::Extern;
            id
        });
        let id = self.open(if declaration.is_some() {
            N::NamespaceBody
        } else {
            N::CompoundStatement
        });
        self.advance();
        if self.at(K::LParen) && !self.line_start() {
            self.group(K::LParen);
        }
        self.items(false);
        self.expect(K::RBrace);
        if self.at(K::LParen) && !self.line_start() {
            self.group(K::LParen);
        }
        self.close(id);
        if let Some(id) = declaration {
            self.close(id);
        }
    }
    fn namespace_macro(&mut self) {
        let id = self.open(N::NamespaceDecl);
        self.advance();
        if self.at(K::LParen) {
            self.group(K::LParen);
        } else {
            self.missing(K::LParen);
        }
        if self.at(K::LBrace) {
            self.body(N::NamespaceBody);
        } else {
            self.missing(K::LBrace);
        }
        self.close(id);
    }
    fn namespace(&mut self) {
        let id = self.open(N::NamespaceDecl);
        self.advance();
        loop {
            match self.kind() {
                K::Identifier | K::ColonColon => self.advance(),
                K::LBracket => self.group(K::LBracket),
                K::LParen => self.group(K::LParen),
                _ => break,
            }
        }
        if self.at(K::Equals) {
            while !matches!(self.kind(), K::EndOfFile | K::Semicolon | K::RBrace)
                && !self.kind().sync()
            {
                self.advance();
            }
            if self.at(K::Semicolon) {
                self.advance();
            }
        } else if self.at(K::LBrace) {
            self.body(N::NamespaceBody);
        } else {
            self.missing(K::LBrace);
        }
        self.close(id);
    }
    fn class(&mut self) {
        let id = self.open(N::ClassDecl);
        let is_enum = self.at(K::EnumKw);
        self.advance();
        let mut equals = false;
        // Parameters just before the brace: `struct tm f(int x) {` defines
        // a function that returns a struct, `struct alignas(8) A {` does not.
        let mut function = false;
        while !matches!(
            self.kind(),
            K::EndOfFile | K::LBrace | K::Semicolon | K::RBrace | K::NamespaceKw
        ) {
            if self.at(K::LParen) {
                self.group(K::LParen);
                function = true;
            } else if self.at(K::Less) {
                if !self.template_args() {
                    self.advance();
                }
                function = false;
            } else {
                equals |= self.at(K::Equals);
                function &= matches!(
                    self.text(self.pos),
                    "const" | "volatile" | "noexcept" | "override" | "&" | "&&"
                );
                self.advance();
            }
        }
        if self.at(K::LBrace) && function && !equals {
            self.tree.nodes[id].kind = N::OpaqueDeclaration;
            self.body(N::CompoundStatement);
            self.close(id);
            return;
        }
        if self.at(K::LBrace) {
            if equals {
                self.tree.nodes[id].kind = N::OpaqueDeclaration;
                self.group(K::LBrace);
            } else {
                let saved = self.enum_body;
                self.enum_body = is_enum;
                self.body(N::ClassBody);
                self.enum_body = saved;
            }
            // Declarators after the body, `} specs[] = {...};`, belong to
            // the declaration as clang-format's line does.
            while !matches!(
                self.kind(),
                K::EndOfFile | K::Semicolon | K::RBrace | K::RParen | K::RBracket
            ) && !self.kind().sync()
                && !self.at(K::PreprocessorHash)
            {
                match self.kind() {
                    k @ (K::LParen | K::LBracket | K::LBrace) => self.group(k),
                    _ => self.advance(),
                }
            }
            if self.at(K::Semicolon) {
                self.advance();
            }
        } else if self.at(K::Semicolon) {
            self.advance();
        } else {
            self.incomplete(id);
        }
        self.close(id);
    }
    fn embedded(&mut self, id: usize) {
        while self.at(K::PreprocessorHash) {
            match self.pp_category(self.pos) {
                DirectiveKind::ConditionalEnd => {
                    if self
                        .phantoms
                        .last()
                        .is_some_and(|scope| self.pp.len() <= scope.branch_depth)
                    {
                        self.incomplete(id);
                        return;
                    }
                    self.pp.pop();
                    self.directive();
                }
                DirectiveKind::ConditionalBranch => {
                    self.incomplete(id);
                    return;
                }
                _ => break,
            }
        }
        if matches!(
            self.kind(),
            K::RBrace | K::EndOfFile | K::ElseKw | K::CaseKw | K::DefaultKw
        ) {
            self.incomplete(id);
        } else {
            self.guarded();
        }
    }
    fn control(&mut self, k: K) {
        let n = match k {
            K::IfKw => N::IfStatement,
            K::ForKw => N::ForStatement,
            K::WhileKw => N::WhileStatement,
            K::DoKw => N::DoStatement,
            _ => N::SwitchStatement,
        };
        let id = self.open(n);
        self.advance();
        if k == K::IfKw {
            while self.at(K::Identifier) {
                self.advance();
            }
        }
        if k != K::DoKw {
            if self.at(K::LParen) {
                self.group(K::LParen);
            } else {
                self.missing(K::LParen);
            }
        }
        if k == K::SwitchKw {
            if self.at(K::LBrace) {
                self.body(N::CompoundStatement);
            } else {
                self.incomplete(id);
            }
        } else if k != K::DoKw || !self.at(K::WhileKw) {
            self.embedded(id);
        }
        if k == K::IfKw && self.at(K::ElseKw) {
            let e = self.open(N::ElseClause);
            self.advance();
            self.embedded(e);
            self.close(e);
        }
        if k == K::DoKw {
            if self.at(K::WhileKw) {
                self.advance();
                if self.at(K::LParen) {
                    self.group(K::LParen);
                } else {
                    self.missing(K::LParen);
                }
                self.expect(K::Semicolon);
            } else {
                self.incomplete(id);
            }
        }
        self.close(id);
    }
    fn case(&mut self) {
        let section = self.open(N::CaseSection);
        let label = self.open(N::CaseLabel);
        self.advance();
        while !matches!(
            self.kind(),
            K::EndOfFile | K::Colon | K::Semicolon | K::LBrace | K::RBrace
        ) {
            if self.at(K::LParen) {
                self.group(K::LParen);
            } else {
                self.advance();
            }
        }
        self.expect(K::Colon);
        self.close(label);
        self.items(true);
        self.close(section);
    }
    fn group(&mut self, opener: K) {
        if self.stack.len() >= MAX_NESTING {
            let id = self.open(N::Error);
            self.advance();
            self.close(id);
            return;
        }
        let (kind, closer) = Self::delimiter(opener);
        let id = self.open(kind);
        self.advance();
        let mut pending = false;
        let mut prev = opener;
        loop {
            let k = self.kind();
            if k == K::Less
                && matches!(prev, K::Identifier | K::TemplateKw)
                && self.template_args_in(true)
            {
                prev = K::Greater;
                continue;
            }
            if k == K::EndOfFile {
                break;
            }
            if k == closer {
                self.advance();
                self.close(id);
                return;
            }
            if matches!(k, K::LParen | K::LBracket) {
                // A nested block follows a lambda introducer and its parameters;
                // `new (place) T{...}` and other parenthesized groups do not open one.
                let lambda = k == K::LBracket || pending;
                self.group(k);
                pending = lambda;
                prev = Self::delimiter(k).1;
                continue;
            }
            if k == K::LBrace && opener != K::LBracket {
                if pending {
                    self.body(N::CompoundStatement);
                } else {
                    self.group(k);
                }
                pending = false;
                prev = K::RBrace;
                continue;
            }
            if opener == K::LParen
                && (matches!(k, K::RBrace | K::NamespaceKw)
                    || (matches!(k, K::ClassKw | K::StructKw)
                        && self.line_start()
                        && self.defines_class()))
            {
                break;
            }
            if opener == K::LBracket
                && (matches!(k, K::Semicolon | K::LBrace | K::RBrace) || k.sync())
            {
                break;
            }
            if opener == K::LBrace {
                if matches!(
                    k,
                    K::Semicolon
                        | K::ReturnKw
                        | K::IfKw
                        | K::WhileKw
                        | K::ForKw
                        | K::DoKw
                        | K::SwitchKw
                ) {
                    self.tree.nodes[id].kind = N::CompoundStatement;
                    self.tree.nodes[id].reclassified = true;
                    self.items(false);
                    self.expect(closer);
                    self.close(id);
                    return;
                }
                if k == K::PreprocessorHash {
                    self.directive();
                    continue;
                }
                if k.sync() {
                    break;
                }
            }
            pending &= Self::suffix(k);
            prev = k;
            self.advance();
        }
        self.missing(closer);
        self.close(id);
    }
    fn template_args(&mut self) -> bool {
        self.template_args_in(false)
    }
    /// In an expression, clang-format's angle heuristics reject comparisons
    /// such as `a < b && c > d` that would otherwise balance.
    fn template_args_in(&mut self, expression: bool) -> bool {
        let Some(end) = self.template_end(expression) else {
            return false;
        };
        self.template_group(end);
        true
    }
    /// Groups inside template arguments, so nested argument lists and
    /// parentheses are scopes for continuation layout. A `>>` closing two
    /// lists ends both nodes at the same token.
    fn template_group(&mut self, end: usize) {
        let id = self.open(N::TemplateArgumentList);
        self.advance();
        while self.pos < end {
            match self.kind() {
                k @ (K::LParen | K::LBracket) if self.stack.len() < MAX_NESTING => self.group(k),
                K::Less if self.stack.len() < MAX_NESTING => match self.template_end(false) {
                    Some(inner) if inner <= end => self.template_group(inner),
                    _ => self.advance(),
                },
                _ => self.advance(),
            }
        }
        self.close(id);
    }
    /// The token index after the `>` closing the argument list at the cursor.
    fn template_end(&mut self, expression: bool) -> Option<usize> {
        self.skip();
        let mut angle = 0isize;
        let mut paren = 0;
        let mut bracket = 0;
        let mut count = 0;
        let mut end = None;
        let mut logical = false;
        let mut ternary = false;
        let source = self.tree.source.as_bytes();
        for i in self.pos..self.tree.tokens.len() {
            let k = self.tree.tokens[i].kind;
            if k.is_trivia() {
                continue;
            }
            count += 1;
            if count > TEMPLATE_LOOKAHEAD {
                break;
            }
            match k {
                K::Less => angle += 1,
                K::Greater => {
                    angle -= 1;
                    if angle == 0 {
                        end = Some(i + 1);
                        break;
                    }
                }
                K::GreaterGreater => {
                    angle -= 2;
                    if angle <= 0 {
                        end = Some(i + 1);
                        break;
                    }
                }
                K::LParen => paren += 1,
                K::RParen => {
                    if paren == 0 {
                        break;
                    }
                    paren -= 1;
                }
                K::LBracket => bracket += 1,
                K::RBracket => {
                    if bracket == 0 {
                        break;
                    }
                    bracket -= 1;
                }
                K::Semicolon | K::LBrace | K::RBrace | K::EndOfFile => break,
                K::PipePipe | K::AmpAmp if paren == 0 && bracket == 0 => {
                    // `&&` without surrounding spaces is a reference declarator.
                    let range = &self.tree.tokens[i].range;
                    logical |= k == K::PipePipe
                        || (range.start > 0
                            && source[range.start - 1].is_ascii_whitespace()
                            && source.get(range.end).is_some_and(u8::is_ascii_whitespace));
                }
                K::Question | K::Colon if paren == 0 && bracket == 0 => ternary = true,
                _ => {}
            }
        }
        let end = end?;
        if expression {
            let tokens = &self.tree.tokens;
            let next = significant_after(tokens, tokens[end - 1].range.end).map(|i| tokens[i].kind);
            let literal = matches!(
                next,
                Some(K::Number | K::StringLiteral | K::CharacterLiteral | K::RawStringLiteral)
            );
            if logical || literal || (ternary && !matches!(next, Some(K::LParen | K::LBrace))) {
                return None;
            }
        }
        Some(end)
    }
    fn ctor(&mut self) {
        let list = self.open(N::CtorInitializerList);
        self.advance();
        let mut expect = true;
        loop {
            let k = self.kind();
            if matches!(k, K::EndOfFile | K::LBrace | K::RBrace | K::Semicolon) || k.sync() {
                break;
            }
            if k == K::Comma {
                self.advance();
                expect = true;
                continue;
            }
            let before = self.pos;
            let item = self.open(N::CtorInitializer);
            let mut named = false;
            while matches!(self.kind(), K::Identifier | K::ColonColon) {
                self.advance();
                named = true;
            }
            if named && self.at(K::Less) {
                self.template_args();
            }
            if self.at(K::LParen) {
                self.group(K::LParen);
            } else if named && self.at(K::LBrace) {
                self.group(K::LBrace);
            } else {
                self.incomplete(item);
            }
            if self.pos == before {
                self.advance();
            }
            expect = false;
            if self.tree.nodes[item].incomplete {
                self.incomplete(list);
            }
            self.close(item);
        }
        if expect {
            self.incomplete(list);
        }
        self.close(list);
    }
    /// A requires clause after template parameters belongs with them, as
    /// clang-format's own line for it does: `requires`, then primaries
    /// joined by `&&` or `||`, each a name with its template arguments or
    /// a parenthesized expression.
    fn requires_clause(&mut self) {
        if !(self.at(K::Identifier) && self.text(self.pos) == "requires") {
            return;
        }
        self.advance();
        loop {
            // A requires expression, `requires (T t) { t.f(); }`.
            if self.at(K::Identifier) && self.text(self.pos) == "requires" {
                self.advance();
            }
            while self.at(K::Exclaim) {
                self.advance();
            }
            match self.kind() {
                K::LParen => self.group(K::LParen),
                // A qualified name, `std::is_same_v<T, U>`, goes on only
                // through `::`; what follows it is the declaration.
                K::Identifier | K::ColonColon => loop {
                    if self.at(K::ColonColon) {
                        self.advance();
                    }
                    if !self.at(K::Identifier) {
                        break;
                    }
                    self.advance();
                    if self.at(K::Less) && !self.template_args() {
                        self.advance();
                    }
                    if !self.at(K::ColonColon) {
                        break;
                    }
                },
                _ => return,
            }
            if self.at(K::LBrace) {
                self.group(K::LBrace);
            }
            if !matches!(self.kind(), K::AmpAmp | K::PipePipe) {
                return;
            }
            self.advance();
        }
    }
    /// Whether the `class` or `struct` here defines one, reaching a body or
    /// a base list before what ends a parameter, as `struct addrinfo* ai,`
    /// does not.
    fn defines_class(&self) -> bool {
        self.tree.tokens[self.pos + 1..]
            .iter()
            .filter(|t| !t.kind.is_trivia())
            .find_map(|t| match t.kind {
                K::LBrace | K::Colon => Some(true),
                K::Comma | K::RParen | K::Semicolon | K::RBrace | K::EndOfFile => Some(false),
                _ => None,
            })
            .unwrap_or(false)
    }
    /// Whether the next significant token could begin a statement, as
    /// clang-format's `tokenCanStartNewLine` asks after a macro call: one
    /// that only continues an expression, like `<<` in
    /// `EXPECT_EQ(a, b)` and `<< "message";` below it, keeps the call going.
    fn can_start_line(&self) -> bool {
        let Some(next) =
            significant_after(&self.tree.tokens, self.tree.tokens[self.pos].range.start)
        else {
            return true;
        };
        !matches!(
            self.tree.tokens[next].kind,
            K::Semicolon
                | K::LBrace
                | K::Period
                | K::PeriodStar
                | K::Arrow
                | K::ArrowStar
                | K::Less
                | K::Greater
                | K::Slash
                | K::Percent
                | K::LessLess
                | K::GreaterGreater
                | K::Equals
                | K::PlusEqual
                | K::MinusEqual
                | K::StarEqual
                | K::SlashEqual
                | K::PercentEqual
                | K::AmpEqual
                | K::PipeEqual
                | K::CaretEqual
                | K::GreaterGreaterEqual
                | K::LessLessEqual
                | K::Colon
        ) && self.text(next) != "noexcept"
    }
    fn statement_macro(&self, spelling: &str) -> bool {
        let options = &self.tree.parser_options;
        if options.attribute_macros.iter().any(|name| name == spelling) {
            return false;
        }
        options.statement_macros.iter().any(|name| name == spelling)
            // Unconfigured all-caps invocations may be standalone statements.
            // This fallback only ends a unit when a call is followed by a newline.
            || (spelling.len() >= 3 && spelling.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_'))
    }

    fn generic(&mut self) {
        let id = self.open(N::OpaqueDeclaration);
        self.tree.nodes[id].whitespace_sensitive = self
            .tree
            .parser_options
            .whitespace_sensitive_macros
            .iter()
            .any(|name| name == self.text(self.pos));
        let mut prev = K::EndOfFile;
        let mut has_question = false;
        let mut expression = false;
        let mut terminated = false;
        let mut body_candidate = false;
        // A lambda introducer seen in expression position; its body is a
        // nested block and does not end the declaration.
        let mut lambda = false;
        let mut standalone_macro = false;
        let mut label_candidate = false;
        let mut linkage = LinkageHead::Other;
        loop {
            let k = self.kind();
            if k == K::EndOfFile {
                break;
            }
            if k == K::Semicolon || (k == K::Comma && self.enum_body) {
                self.advance();
                terminated = true;
                break;
            }
            if k == K::RBrace {
                terminated = self.enum_body;
                break;
            }
            if k.sync() {
                // `using namespace std;` names a namespace, opening none.
                let using = k == K::NamespaceKw
                    && self.tree.tokens[..self.pos]
                        .iter()
                        .rposition(|t| !t.kind.is_trivia())
                        .is_some_and(|before| self.text(before) == "using");
                if (k == K::DefaultKw && prev == K::Equals) || using {
                    self.advance();
                    prev = k;
                    continue;
                }
                break;
            }
            if k == K::LParen {
                let parameters = lambda;
                self.group(k);
                if standalone_macro && self.newline_ahead() && self.can_start_line() {
                    terminated = true;
                    break;
                }
                standalone_macro = false;
                label_candidate = false;
                prev = K::RParen;
                body_candidate = !parameters;
                continue;
            }
            if k == K::LBracket {
                let subscript = matches!(
                    prev,
                    K::Identifier
                        | K::RParen
                        | K::RBracket
                        | K::Greater
                        | K::StringLiteral
                        | K::Number
                        | K::OperatorKw
                );
                let attribute = prev == K::EndOfFile
                    && significant_after(&self.tree.tokens, self.tree.tokens[self.pos].range.end)
                        .is_some_and(|i| self.tree.tokens[i].kind == K::LBracket);
                self.group(k);
                standalone_macro = false;
                label_candidate = false;
                prev = K::RBracket;
                lambda = !subscript && !attribute;
                continue;
            }
            if k == K::LBrace {
                if linkage == LinkageHead::ExternString {
                    self.tree.nodes[id].kind = N::NamespaceDecl;
                    self.tree.nodes[id].extern_linkage = true;
                    self.body(N::NamespaceBody);
                    terminated = true;
                    break;
                }
                if lambda {
                    self.body(N::CompoundStatement);
                    lambda = false;
                    label_candidate = false;
                    prev = K::RBrace;
                    continue;
                }
                if body_candidate {
                    self.tree.nodes[id].kind = N::FunctionDefinition;
                    self.body(N::CompoundStatement);
                    terminated = true;
                    break;
                }
                self.group(k);
                label_candidate = false;
                prev = K::RBrace;
                continue;
            }
            if k == K::Colon && label_candidate {
                self.advance();
                terminated = true;
                break;
            }
            if k == K::Colon && body_candidate && !has_question {
                self.tree.nodes[id].kind = N::FunctionDefinition;
                self.ctor();
                if self.at(K::LBrace) {
                    self.body(N::CompoundStatement);
                } else {
                    self.missing(K::LBrace);
                }
                terminated = true;
                break;
            }
            if k == K::Less
                && matches!(prev, K::Identifier | K::TemplateKw)
                && self.template_args_in(expression)
            {
                label_candidate = false;
                prev = K::Greater;
                continue;
            }
            has_question |= k == K::Question;
            // After these an `<` may be a comparison; before them it opens
            // the arguments of a declaration's type.
            expression |= matches!(k, K::ReturnKw | K::Equals);
            body_candidate &= Self::suffix(k);
            lambda &= Self::suffix(k);
            let first = prev == K::EndOfFile && k == K::Identifier;
            let spelling = self.text(self.pos);
            let spelling_len = spelling.len();
            standalone_macro = first && self.statement_macro(spelling);
            label_candidate = first;
            linkage = if first && self.text(self.pos) == "extern" {
                LinkageHead::Extern
            } else if linkage == LinkageHead::Extern && k == K::StringLiteral {
                LinkageHead::ExternString
            } else {
                LinkageHead::Other
            };
            self.advance();
            prev = k;
            // `ABSL_NAMESPACE_BEGIN` alone on a line is a statement of its
            // own, as clang-format takes an all-caps name of five letters or
            // more before a line that can start one.
            if standalone_macro
                && spelling_len >= 5
                && self.newline_ahead()
                && significant_after(&self.tree.tokens, self.tree.tokens[self.pos].range.start)
                    .is_none_or(|next| self.tree.tokens[next].kind != K::LParen)
                && self.can_start_line()
            {
                terminated = true;
                break;
            }
        }
        if !terminated {
            self.incomplete(id);
        }
        self.close(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directive_classification_stops_at_its_logical_line() {
        for (source, expected) in [
            ("#\nif (x) {}", DirectiveKind::Other),
            ("# /* comment */\nelse {}", DirectiveKind::Other),
            ("# /* comment */ if X", DirectiveKind::ConditionalStart),
            ("#\\\nif X", DirectiveKind::ConditionalStart),
            ("#elif X", DirectiveKind::ConditionalBranch),
            ("#endif", DirectiveKind::ConditionalEnd),
        ] {
            let parser = Parser::new(source.into(), &ParserOptions::default(), lex(source));
            assert_eq!(parser.pp_category(0), expected, "{source}");
        }
    }
}
