//! Local solver choices derived from resolved C++ behavior.
use super::{
    AccessIndent, ConstructorInitializers as CI, CppRules, ExternIndentation, InitializerLayout,
    NamespaceIndentation as NI,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum IndentSegment {
    Structural,
    Continuation,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct OffsetRule {
    pub columns: isize,
    pub segment: IndentSegment,
}
impl OffsetRule {
    pub(super) fn target(self, base: usize) -> usize {
        base.saturating_add_signed(self.columns)
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum AlignmentAnchor {
    FirstElement,
    FirstInitializer,
    ConstructorColon,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum IndentRule {
    Offset(OffsetRule),
    Align {
        anchor: AlignmentAnchor,
        columns: isize,
        fallback: OffsetRule,
    },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum IndentSlot {
    NamespaceOuter,
    NamespaceInner,
    ExternOuter,
    ExternInner,
    MembersBeforeAccess,
    MembersAfterAccess,
    AccessLabel,
    BlockBody,
    SingleStatementBody,
    CaseLabel,
    CaseBody,
    ConstructorIntro,
    ConstructorItem,
    WrappedFunctionName,
    StatementContinuation,
    ParameterContinuation,
    BracedInitializer,
    PreprocessorBody,
    EnumBody,
}
pub(super) fn rule(policy: &CppRules, slot: IndentSlot) -> IndentRule {
    use IndentSlot as S;
    let w = policy.whitespace.indent_width;
    let cont = policy.expression.continuation_width;
    let structural = |n: usize| OffsetRule {
        columns: n as isize,
        segment: IndentSegment::Structural,
    };
    let continuation = |n: usize| OffsetRule {
        columns: n as isize,
        segment: IndentSegment::Continuation,
    };
    let namespace = |outer: bool| {
        if policy.structure.namespace == NI::All
            || (!outer && policy.structure.namespace == NI::Inner)
        {
            w
        } else {
            0
        }
    };
    let extern_body = |outer| match policy.structure.extern_body {
        ExternIndentation::None => 0,
        ExternIndentation::Indent => w,
        ExternIndentation::FollowNamespace => namespace(outer),
    };
    let offset = match slot {
        S::NamespaceOuter => structural(namespace(true)),
        S::NamespaceInner => structural(namespace(false)),
        S::ExternOuter => structural(extern_body(true)),
        S::ExternInner => structural(extern_body(false)),
        S::MembersBeforeAccess | S::MembersAfterAccess => {
            structural(if !policy.structure.indent_type_body {
                0
            } else if policy.structure.access == AccessIndent::Always
                || (slot == S::MembersAfterAccess
                    && policy.structure.access == AccessIndent::AfterFirstAccessModifier)
            {
                2 * w
            } else {
                w
            })
        }
        S::EnumBody => structural(if policy.structure.indent_type_body {
            w
        } else {
            0
        }),
        S::AccessLabel => OffsetRule {
            columns: if policy.structure.access == AccessIndent::Never {
                (w as isize).saturating_add(policy.structure.access_offset)
            } else {
                w as isize
            },
            segment: IndentSegment::Structural,
        },
        S::BlockBody | S::SingleStatementBody | S::PreprocessorBody => structural(w),
        S::CaseLabel => structural(if policy.structure.indent_case_labels {
            w
        } else {
            0
        }),
        S::CaseBody => structural(if policy.structure.indent_case_body {
            w
        } else {
            0
        }),
        S::ConstructorIntro => continuation(policy.constructor.width),
        S::WrappedFunctionName => continuation(if policy.structure.indent_wrapped_function_names {
            cont
        } else {
            0
        }),
        S::StatementContinuation => continuation(cont),
        S::ParameterContinuation | S::BracedInitializer => {
            let fallback = if slot == S::ParameterContinuation {
                continuation(cont)
            } else if policy.initializer.layout == InitializerLayout::Continuation {
                continuation(policy.initializer.width)
            } else {
                structural(policy.initializer.width)
            };
            return if policy.expression.align_parentheses {
                IndentRule::Align {
                    anchor: AlignmentAnchor::FirstElement,
                    columns: 0,
                    fallback,
                }
            } else {
                IndentRule::Offset(fallback)
            };
        }
        S::ConstructorItem => {
            let fallback = continuation(policy.constructor.width);
            let (anchor, columns) = match policy.constructor.layout {
                CI::NormalIndent => return IndentRule::Offset(structural(w)),
                CI::ContinuationIndent => return IndentRule::Offset(fallback),
                CI::AlignFirstInitializer => (AlignmentAnchor::FirstInitializer, 0),
                CI::AlignAfterColon => (AlignmentAnchor::ConstructorColon, 2),
                CI::AlignWithColon => (AlignmentAnchor::ConstructorColon, 0),
            };
            return IndentRule::Align {
                anchor,
                columns,
                fallback,
            };
        }
    };
    IndentRule::Offset(offset)
}
pub(super) fn offset(policy: &CppRules, slot: IndentSlot) -> OffsetRule {
    match rule(policy, slot) {
        IndentRule::Offset(rule) => rule,
        IndentRule::Align { fallback, .. } => fallback,
    }
}
