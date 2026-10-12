// Parts of this algorithm are adapted from LLVM clang-format.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// See third_party/llvm/LICENSE.txt.
// This Rust adaptation replays user-selected line breaks and actual columns;
// it does not run the formatter's line-breaking optimizer.

use super::whitespace::column_width;
use super::{CppRules, NodeKind as N, SyntaxTree, TokenKind as K};
use crate::core::Snapshot;

#[derive(Clone, Debug)]
struct Sim {
    kind: K,
    length: i64,
    column: i64,
    newline: bool,
    scope: i8,
    close_count: usize,
    block: bool,
    braced: bool,
    multi: bool,
    binary: bool,
    unary: bool,
    precedence: i32,
    operator_index: usize,
    next_operator: bool,
    starts_binary: bool,
    question: bool,
    colon: bool,
    ctor: bool,
    member: bool,
    shift: bool,
    fake_left: Vec<i32>,
    fake_right: usize,
}
impl Sim {
    fn new(kind: K) -> Self {
        Self {
            kind,
            length: 0,
            column: 0,
            newline: false,
            scope: 0,
            close_count: 1,
            block: false,
            braced: false,
            multi: false,
            binary: false,
            unary: false,
            precedence: -1,
            operator_index: 0,
            next_operator: false,
            starts_binary: false,
            question: false,
            colon: false,
            ctor: false,
            member: false,
            shift: false,
            fake_left: vec![],
            fake_right: 0,
        }
    }
    fn operand(&self) -> bool {
        self.scope == -1
            || matches!(
                self.kind,
                K::Identifier
                    | K::Number
                    | K::StringLiteral
                    | K::RawStringLiteral
                    | K::CharacterLiteral
            )
    }
    fn string(&self) -> bool {
        matches!(self.kind, K::StringLiteral | K::RawStringLiteral)
    }
    fn unary_spelling(&self) -> bool {
        matches!(
            self.kind,
            K::Plus
                | K::Minus
                | K::Star
                | K::Amp
                | K::Exclaim
                | K::Tilde
                | K::PlusPlus
                | K::MinusMinus
        )
    }
    fn precedence(&self) -> i32 {
        use K::*;
        match self.kind {
            Comma => 1,
            Equals | PlusEqual | MinusEqual | StarEqual | SlashEqual | PercentEqual | AmpEqual
            | PipeEqual | CaretEqual | LessLessEqual | GreaterGreaterEqual => 2,
            PipePipe => 4,
            AmpAmp => 5,
            Pipe => 6,
            Caret => 7,
            Amp => 8,
            EqualEqual | ExclaimEqual => 9,
            Less | Greater | LessEqual | GreaterEqual => 10,
            Spaceship => 11,
            LessLess | GreaterGreater => 12,
            Plus | Minus => 13,
            Star | Slash | Percent => 14,
            PeriodStar | ArrowStar => 15,
            Period | Arrow => 17,
            _ => -1,
        }
    }
}
struct Fake<'a> {
    tokens: &'a mut [Sim],
    pos: usize,
    depth: usize,
}
impl Fake<'_> {
    fn current(&self) -> i32 {
        let Some(t) = self.tokens.get(self.pos) else {
            return -1;
        };
        if t.question || t.colon {
            3
        } else if t.kind == K::Semicolon {
            0
        } else if t.member {
            17
        } else if t.binary || t.kind == K::Comma {
            t.precedence
        } else {
            -1
        }
    }
    fn add(&mut self, start: usize, prec: i32) {
        if start >= self.tokens.len() {
            return;
        }
        self.tokens[start].fake_left.push(prec);
        self.tokens[start].starts_binary |= prec > 0;
        if self.pos < self.tokens.len() {
            self.tokens[self.pos.saturating_sub(1)].fake_right += 1;
        }
    }
    fn parse(&mut self, prec: i32) {
        if self.depth >= 128 {
            self.pos = self.tokens.len();
            return;
        }
        self.depth += 1;
        self.parse_inner(prec);
        self.depth -= 1;
    }
    fn parse_inner(&mut self, prec: i32) {
        while self
            .tokens
            .get(self.pos)
            .is_some_and(|t| t.kind == K::ReturnKw)
        {
            self.pos += 1;
        }
        if self.pos >= self.tokens.len() || prec > 17 {
            return;
        }
        if prec == 3 {
            let start = self.pos;
            self.parse(4);
            if !self.tokens.get(self.pos).is_some_and(|t| t.question) {
                return;
            }
            self.pos += 1;
            self.parse(2);
            if !self.tokens.get(self.pos).is_some_and(|t| t.colon) {
                return;
            }
            self.pos += 1;
            self.parse(2);
            self.add(start, 3);
            return;
        }
        if prec == 16 {
            let mut unaries = vec![];
            while self.tokens.get(self.pos).is_some_and(|t| t.unary) {
                unaries.push(self.pos);
                self.pos += 1;
            }
            self.parse(17);
            for start in unaries.into_iter().rev() {
                self.add(start, 0);
            }
            return;
        }
        let start = self.pos;
        let mut latest: Option<usize> = None;
        let mut index = 0;
        while self.pos < self.tokens.len() {
            self.parse(prec + 1);
            let current = self.current();
            if self.pos >= self.tokens.len()
                || self.tokens[self.pos].scope == -1
                || (current != -1 && current < prec)
                || (current == 3 && prec == 2 && self.tokens[self.pos].colon)
            {
                break;
            }
            if self.tokens[self.pos].scope == 1 {
                while self.pos < self.tokens.len() && self.tokens[self.pos].scope != -1 {
                    self.pos += 1;
                    self.parse(0);
                }
                self.pos += 1;
            } else {
                if current == prec {
                    if let Some(last) = latest {
                        self.tokens[last].next_operator = true;
                    }
                    latest = Some(self.pos);
                    self.tokens[self.pos].operator_index = index;
                    index += 1;
                }
                self.pos += 1;
            }
        }
        if latest.is_some() && (self.pos < self.tokens.len() || prec > 0) {
            self.add(start, if prec == 17 { 0 } else { prec });
        }
    }
}
#[derive(Clone, Default)]
struct Frame {
    structural: i64,
    aligned: bool,
    indent: i64,
    last: i64,
    nested: i64,
    question: i64,
    shift: i64,
    call: i64,
    variable: i64,
    start_call: i64,
    wrapped: bool,
}
struct Replay<'a> {
    stack: Vec<Frame>,
    first: i64,
    style: &'a CppRules,
    string: i64,
    depth: i64,
}
impl Replay<'_> {
    fn top(&self) -> &Frame {
        self.stack.last().unwrap()
    }
    fn top_mut(&mut self) -> &mut Frame {
        self.stack.last_mut().unwrap()
    }
    fn step(
        &mut self,
        t: &Sim,
        prev: Option<&Sim>,
        prev2: Option<&Sim>,
        prev_nc: Option<&Sim>,
        next: Option<&Sim>,
    ) {
        let col = t.column;
        if t.newline {
            let f = self.top_mut();
            f.nested = col;
            if t.member && f.call == 0 {
                f.call = col;
            }
            f.last = col + if t.shift { 3 } else { 0 };
        } else if let Some(p) = prev {
            if t.kind == K::Equals && self.depth == 0 && self.top().variable == 0 {
                let variable = prev2
                    .filter(|p2| {
                        matches!(p2.kind, K::Star | K::Amp) && p2.column + p2.length == p.column
                    })
                    .map_or(p.column, |p2| p2.column);
                self.top_mut().variable = variable;
            }
            if self.style.expression.align_parentheses && p.scope == 1 && !p.block {
                self.top_mut().indent = col;
                self.top_mut().aligned = true;
            }
            if p.scope == 1 && prev2.is_some_and(|p2| matches!(p2.kind, K::IfKw | K::ForKw)) {
                self.top_mut().last = col;
                self.top_mut().nested = col;
            } else if p.kind == K::Comma
                || p.question
                || p.colon
                || p.ctor
                || (p.binary
                    && ((p.precedence != 2
                        && (!p.shift || p.operator_index != 0 || p.next_operator))
                        || t.starts_binary))
            {
                self.top_mut().last = col;
            }
        }
        if t.shift && self.top().shift == 0 {
            self.top_mut().shift = col;
        }
        if self.style.expression.anchor_ternary_before_operator && t.question {
            self.top_mut().question = col;
        }
        if !self.style.expression.anchor_ternary_before_operator
            && prev.is_some_and(|p| p.question)
            && !t.colon
        {
            self.top_mut().question = col;
        }
        if t.question && (t.newline || next.is_some_and(|t| t.newline)) {
            self.top_mut().wrapped = true;
        }
        if t.member {
            self.top_mut().start_call = if t.next_operator { col } else { 0 };
        }
        if t.ctor {
            let indent = col
                + if self.style.constructor.layout == super::ConstructorInitializers::AlignWithColon
                {
                    0
                } else {
                    2
                };
            self.top_mut().indent = indent;
            self.top_mut().nested = indent;
        }
        if (t.binary || t.question || t.colon) && t.newline {
            self.top_mut().nested = col + t.length + 1;
        }
        let mut skip = prev_nc.is_some_and(|p| {
            p.scope == 1
                || matches!(p.kind, K::Semicolon | K::ReturnKw)
                || (p.binary
                    && p.precedence == 2
                    && (self.style.expression.operand_alignment != super::OperandAlignment::None))
        });
        for (index, &level) in t.fake_left.iter().rev().enumerate() {
            let mut state = self.top().clone();
            state.wrapped = false;
            let align = (self.style.expression.operand_alignment != super::OperandAlignment::None)
                || level < 2;
            let after_return = prev_nc.is_some_and(|p| p.kind == K::ReturnKw) && level == 0;
            if align
                && !after_return
                && (self.style.expression.align_parentheses || level > 1 || self.depth == 0)
            {
                state.indent = state.indent.max(t.column).max(self.top().last);
                state.aligned = true;
            }
            if level > 0 {
                state.last = state.last.max(t.column);
            }
            if level != 3 && !t.unary && self.style.expression.align_parentheses {
                state.start_call = t.column;
            }
            let chained = level == 3
                && prev_nc.is_some_and(|p| p.colon)
                && index + 1 == t.fake_left.len()
                && !self.top().wrapped;
            if !chained && (level == 3 || (!skip && level > 2)) {
                state.indent += self.style.expression.continuation_width as i64;
            }
            self.stack.push(state);
            skip = false;
        }
        if t.scope == -1 {
            for _ in 0..t.close_count {
                if self.stack.len() > 1 {
                    self.stack.pop();
                }
                self.depth -= 1;
            }
        }
        if t.scope == 1 {
            let top = self.top();
            let mut state = Frame {
                structural: top.structural,
                last: top.last,
                ..Frame::default()
            };
            if t.block {
                state.indent = top.indent;
            } else if t.braced {
                if self.style.initializer.layout == super::InitializerLayout::Block {
                    state.structural += self.style.initializer.width as i64;
                }
                state.indent = top.last + self.style.initializer.width as i64;
                state.nested = top.start_call.max(top.nested);
                if t.multi {
                    state.nested = state.nested.max(t.column + 1);
                }
            } else {
                state.indent =
                    top.last.max(top.start_call) + self.style.expression.continuation_width as i64;
                state.nested = top.start_call.max(top.nested);
                if t.kind == K::Less {
                    state.indent = state.indent.max(top.indent);
                    state.last = state.last.max(top.indent);
                }
            }
            self.stack.push(state);
            self.depth += 1;
        }
        for _ in 0..t.fake_right {
            if self.stack.len() > 1 {
                let variable = self.top().variable;
                self.stack.pop();
                self.top_mut().variable = variable;
            }
        }
        if t.string() {
            if self.string == 0 {
                self.string = col;
            }
        } else if !matches!(
            t.kind,
            K::Identifier | K::PreprocessorHash | K::LineComment | K::BlockComment
        ) {
            self.string = 0;
        }
    }
    fn column(&self, t: &Sim, prev: Option<&Sim>) -> i64 {
        let f = self.top();
        let cont = self.style.expression.continuation_width as i64;
        let continuation = f.last.max(f.indent) + cont;
        if matches!(t.kind, K::RBrace | K::RBracket | K::RParen) && self.stack.len() > 1 {
            return self.stack[self.stack.len() - 2].last;
        }
        if t.string() && self.string != 0 {
            return self.string;
        }
        if t.shift && f.shift != 0 {
            return f.shift;
        }
        if t.member {
            return if f.call == 0 { continuation } else { f.call };
        }
        if f.question != 0 && (t.colon || prev.is_some_and(|p| p.question || p.colon)) {
            let chained = (t.colon || prev.is_some_and(|p| p.colon))
                && t.fake_left.last() == Some(&3)
                && !f.wrapped;
            if chained {
                return f.indent
                    - if self.style.expression.operand_alignment != super::OperandAlignment::None {
                        cont
                    } else {
                        0
                    };
            }
            return f.question;
        }
        if prev.is_some_and(|p| p.kind == K::Comma) && f.variable != 0 {
            return f.variable;
        }
        if prev.is_some_and(|p| matches!(p.kind, K::ColonColon | K::Equals)) {
            return continuation;
        }
        if prev.is_some_and(|p| p.kind == K::RParen) && !t.binary && t.kind != K::Colon {
            return continuation;
        }
        if f.indent == self.first && prev.is_some_and(|p| p.kind != K::RBrace) {
            return f.indent + cont;
        }
        f.indent
    }
}
fn block(k: N) -> bool {
    matches!(
        k,
        N::TranslationUnit
            | N::CompoundStatement
            | N::NamespaceBody
            | N::ClassBody
            | N::CaseSection
    )
}
fn group(k: N) -> bool {
    matches!(
        k,
        N::ParenGroup | N::BracketGroup | N::BraceGroup | N::TemplateArgumentList
    )
}

pub(super) struct ContinuationColumn {
    pub target: usize,
    pub structural: usize,
    pub continuation: usize,
}

pub(super) fn continuation(
    snapshot: &Snapshot,
    tree: &SyntaxTree,
    line: usize,
    controlling: usize,
    style: &CppRules,
) -> Option<ContinuationColumn> {
    let mut region = controlling;
    while let Some(parent) = tree.nodes[region].parent {
        if block(tree.nodes[parent].kind) {
            break;
        }
        region = parent;
        if tree.nodes[region].kind == N::PreprocessorDirective {
            return None;
        }
    }
    let node = &tree.nodes[region];
    if node.tokens.len() > 4096 {
        return None;
    }
    let line_start = snapshot.line_start(line)?;
    let mut first = node.tokens.start;
    let first_line = snapshot.line_of(tree.tokens[first].range.start)?;
    let mut i = first;
    while i > 0 {
        let t = &tree.tokens[i - 1];
        if t.kind.is_trivia() {
            i -= 1;
            continue;
        }
        if snapshot.line_of(t.range.start)? != first_line
            || matches!(t.kind, K::Semicolon | K::Colon | K::LBrace | K::RBrace)
        {
            break;
        }
        i -= 1;
        first = i;
    }
    let mut interiors = vec![];
    let mut bounds = vec![];
    let mut pending = tree.nodes[region].children.clone();
    while let Some(id) = pending.pop() {
        let n = &tree.nodes[id];
        if n.kind == N::CompoundStatement && !n.tokens.is_empty() {
            interiors.push(n.tokens.start + 1..n.tokens.end - 1);
            bounds.extend([n.tokens.start, n.tokens.end - 1]);
        } else {
            pending.extend(&n.children);
        }
    }
    let column = |offset| {
        let line = snapshot.line_of(offset).unwrap();
        column_width(
            &snapshot.text()[snapshot.line_start(line).unwrap()..offset],
            0,
            style.whitespace.tab_width,
        ) as i64
    };
    let mut sim: Vec<Sim> = vec![];
    let mut replay = None;
    let mut query = None;
    let mut previous_line = first_line;
    let mut questions = vec![];
    let mut after_operator = false;
    for i in first..node.tokens.end {
        let t = &tree.tokens[i];
        let comment = matches!(t.kind, K::LineComment | K::BlockComment);
        if (t.kind.is_trivia() && !comment)
            || t.kind == K::EndOfFile
            || t.range.is_empty()
            || interiors.iter().any(|r| r.contains(&i))
        {
            continue;
        }
        let token_line = snapshot.line_of(t.range.start)?;
        if comment && token_line == previous_line {
            continue;
        }
        if t.range.start >= line_start {
            replay.get_or_insert(sim.len());
            if token_line == line && !comment {
                query.get_or_insert(sim.len());
            }
        }
        let mut s = Sim::new(t.kind);
        s.column = column(t.range.start);
        s.length = column_width(
            &snapshot.text()[t.range.clone()],
            s.column as usize,
            style.whitespace.tab_width,
        ) as i64
            - s.column;
        s.newline = token_line != previous_line;
        previous_line = token_line;
        let deepest = tree.node_at(t.range.start);
        let n = &tree.nodes[deepest];
        if i == n.tokens.start {
            match n.kind {
                N::IfStatement => s.kind = K::IfKw,
                N::ForStatement => s.kind = K::ForKw,
                _ => {}
            }
        }

        if bounds.contains(&i) {
            s.scope = if t.kind == K::LBrace { 1 } else { -1 };
            s.block = true;
        } else if group(n.kind) && i == n.tokens.start {
            s.scope = 1;
            s.braced = n.kind == N::BraceGroup;
            s.multi = (n.tokens.start + 1..n.tokens.end.saturating_sub(1)).any(|j| {
                tree.tokens[j].kind == K::Comma
                    && tree.node_at(tree.tokens[j].range.start) == deepest
            });
        } else if group(n.kind)
            && i + 1 == n.tokens.end
            && matches!(
                t.kind,
                K::RParen | K::RBracket | K::RBrace | K::Greater | K::GreaterGreater
            )
        {
            s.scope = -1;
            s.braced = n.kind == N::BraceGroup;
            let mut parent = n.parent;
            while let Some(id) = parent {
                let n = &tree.nodes[id];
                if !group(n.kind) || i + 1 != n.tokens.end {
                    break;
                }
                s.close_count += 1;
                parent = n.parent;
            }
        }
        if s.scope == 0 && !after_operator {
            let prev = sim.last();
            let operand = prev.is_some_and(Sim::operand);
            if t.kind == K::Colon {
                if n.kind == N::CtorInitializerList
                    || n.parent
                        .is_some_and(|p| tree.nodes[p].kind == N::CtorInitializerList)
                {
                    s.ctor = true;
                } else if questions.pop().is_some() {
                    s.colon = true;
                }
            } else if t.kind == K::Question {
                s.question = true;
                questions.push(sim.len());
            } else if t.kind == K::Comma {
                s.precedence = 1;
            } else {
                let prec = s.precedence();
                let bytes = snapshot.text().as_bytes();
                let before = t.range.start > 0 && bytes[t.range.start - 1].is_ascii_whitespace();
                let after = bytes.get(t.range.end).is_some_and(u8::is_ascii_whitespace);
                let ambiguous =
                    matches!(t.kind, K::Star | K::Amp | K::AmpAmp | K::Less | K::Greater);
                if matches!(t.kind, K::Arrow | K::Period | K::ArrowStar | K::PeriodStar) {
                    s.member = operand;
                } else if prec == 2 {
                    s.binary = true;
                    s.precedence = 2;
                } else if prec > 0 && operand && (!ambiguous || (before && after)) {
                    s.binary = true;
                    s.precedence = prec;
                    s.shift = t.kind == K::LessLess;
                } else if !operand {
                    s.unary = s.unary_spelling();
                }
            }
        }
        after_operator = t.kind == K::OperatorKw;
        sim.push(s);
    }
    let count = replay.unwrap_or(sim.len());
    if count == 0 {
        return None;
    }
    Fake {
        tokens: &mut sim,
        pos: 0,
        depth: 0,
    }
    .parse(0);
    let synthetic = Sim::new(K::Identifier);
    let query = query.map(|i| &sim[i]).unwrap_or(&synthetic);
    let first_indent = column_width(
        &snapshot.line(first_line)?[..snapshot
            .line(first_line)?
            .bytes()
            .take_while(|&b| b == b' ' || b == b'\t')
            .count()],
        0,
        style.whitespace.tab_width,
    ) as i64;
    let mut replay = Replay {
        stack: vec![Frame {
            structural: first_indent,
            indent: first_indent,
            last: first_indent,
            nested: first_indent,
            ..Frame::default()
        }],
        first: first_indent,
        style,
        string: 0,
        depth: 0,
    };
    let mut nc = None;
    for i in 0..count {
        replay.step(
            &sim[i],
            i.checked_sub(1).map(|j| &sim[j]),
            i.checked_sub(2).map(|j| &sim[j]),
            nc,
            sim.get(i + 1).filter(|_| i + 1 < count),
        );
        if !matches!(sim[i].kind, K::LineComment | K::BlockComment) {
            nc = Some(&sim[i]);
        }
    }
    let target = replay.column(query, nc).max(0) as usize;
    let structural = replay.top().structural.max(0) as usize;
    let aligned = replay.top().aligned
        || (query.string() && replay.string != 0)
        || (query.shift && replay.top().shift != 0)
        || query.member
        || (replay.top().question != 0
            && (query.colon || nc.is_some_and(|p| p.question || p.colon)))
        || (nc.is_some_and(|p| p.kind == K::Comma) && replay.top().variable != 0);
    Some(ContinuationColumn {
        target,
        structural,
        continuation: if aligned { structural } else { target },
    })
}
