use std::{fmt, num::NonZeroUsize};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NamespaceIndentation {
    None,
    Inner,
    All,
}
/// clang-format's IndentGotoLabels: where a goto label stands against the
/// statements of its block.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GotoLabelIndent {
    /// At column zero.
    None,
    /// A level out from the statements.
    Outer,
    /// With the statements.
    Inner,
    /// Half a level out.
    Half,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PPDirectiveIndent {
    None,
    Leave,
    AfterHash,
    BeforeHash,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConstructorInitializers {
    NormalIndent,
    ContinuationIndent,
    AlignFirstInitializer,
    AlignAfterColon,
    AlignWithColon,
}
pub use crate::language::TabPolicy;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AccessIndent {
    Never,
    Always,
    AfterFirstAccessModifier,
}

#[derive(Clone, Debug, Eq, PartialEq)]
/// Rust-side style builder; configuration adapters compile it before editing.
pub struct CppStyle {
    pub parser: super::ParserOptions,
    pub indent_width: usize,
    pub disable_format: bool,
    pub access_indent: AccessIndent,
    pub constructor_indent: Option<usize>,
    pub braced_initializer_indent: Option<usize>,
    pub indent_extern_body: Option<bool>,
    pub continuation_indent: usize,
    pub tab_width: NonZeroUsize,
    pub tabs: TabPolicy,
    pub align_open_bracket: bool,
    pub brace_init_continuation: bool,
    pub indent_wrapped_function_names: bool,
    pub operand_alignment: super::OperandAlignment,
    pub break_before_ternary: bool,
    pub namespace_indentation: NamespaceIndentation,
    pub indent_type_body: bool,
    pub indent_case_label: bool,
    pub indent_case_body: bool,
    /// clang-format's IndentCaseBlocks: a block a case label opens is an
    /// ordinary statement of the case, not one at the label's level.
    pub indent_case_blocks: bool,
    /// clang-format's IndentRequiresClause, for a clause on its own line.
    pub indent_requires_clause: bool,
    pub goto_labels: GotoLabelIndent,
    /// clang-format's `LambdaBodyIndentation: OuterScope`.
    pub lambda_outer_scope: bool,
    /// Signed label offset from the declaration indentation.
    pub access_specifier_offset: isize,
    pub pp_directive_indent: PPDirectiveIndent,
    pub pp_indent_width: Option<usize>,
    pub constructor_initializers: ConstructorInitializers,
}
impl Default for CppStyle {
    fn default() -> Self {
        Self {
            parser: super::ParserOptions::default(),
            indent_width: 4,
            disable_format: false,
            access_indent: AccessIndent::Never,
            constructor_indent: None,
            braced_initializer_indent: None,
            indent_extern_body: None,
            continuation_indent: 4,
            tab_width: NonZeroUsize::new(4).unwrap(),
            tabs: TabPolicy::Never,
            align_open_bracket: true,
            brace_init_continuation: false,
            indent_wrapped_function_names: true,
            operand_alignment: super::OperandAlignment::FirstOperand,
            break_before_ternary: true,
            namespace_indentation: NamespaceIndentation::None,
            indent_type_body: true,
            indent_case_label: false,
            indent_case_body: true,
            indent_case_blocks: false,
            indent_requires_clause: true,
            goto_labels: GotoLabelIndent::Outer,
            lambda_outer_scope: false,
            access_specifier_offset: 0,
            pp_directive_indent: PPDirectiveIndent::None,
            pp_indent_width: None,
            constructor_initializers: ConstructorInitializers::AlignFirstInitializer,
        }
    }
}

/// Invalid editor-authored style; no executable policy is produced.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StyleError {
    pub field: &'static str,
    pub message: &'static str,
}
impl fmt::Display for StyleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.field, self.message)
    }
}
impl std::error::Error for StyleError {}

pub(crate) fn validate_width(width: usize) -> Result<(), &'static str> {
    if width <= 4096 {
        Ok(())
    } else {
        Err("expected a width between 0 and 4096")
    }
}
pub(crate) fn validate_offset(offset: isize) -> Result<(), &'static str> {
    if (-4096..=4096).contains(&offset) {
        Ok(())
    } else {
        Err("offset is outside the supported range")
    }
}
impl CppStyle {
    pub(super) fn validate(&self) -> Result<(), StyleError> {
        for (field, pattern) in [
            ("macro_block_begin", &self.parser.macro_block_begin),
            ("macro_block_end", &self.parser.macro_block_end),
        ] {
            if !pattern.is_empty() {
                regex::Regex::new(pattern).map_err(|_| StyleError {
                    field,
                    message: "invalid block macro regular expression",
                })?;
            }
        }
        for (field, width) in [
            ("indent_width", Some(self.indent_width)),
            ("continuation_indent", Some(self.continuation_indent)),
            ("tab_width", Some(self.tab_width.get())),
            ("constructor_indent", self.constructor_indent),
            ("braced_initializer_indent", self.braced_initializer_indent),
            ("pp_indent_width", self.pp_indent_width),
        ] {
            if let Some(width) = width {
                validate_width(width).map_err(|message| StyleError { field, message })?;
            }
        }
        let offset = self
            .access_specifier_offset
            .checked_sub(self.indent_width as isize)
            .ok_or(StyleError {
                field: "access_specifier_offset",
                message: "offset is outside the supported range",
            })?;
        validate_offset(offset).map_err(|message| StyleError {
            field: "access_specifier_offset",
            message,
        })
    }
}
