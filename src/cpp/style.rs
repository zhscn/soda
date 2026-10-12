use std::num::NonZeroUsize;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NamespaceIndentation {
    None,
    Inner,
    All,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PPDirectiveIndent {
    None,
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
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TabPolicy {
    Never,
    ForIndentation,
    ForContinuationAndIndentation,
    AlignWithSpaces,
    Always,
}

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
            access_specifier_offset: 0,
            pp_directive_indent: PPDirectiveIndent::None,
            pp_indent_width: None,
            constructor_initializers: ConstructorInitializers::AlignFirstInitializer,
        }
    }
}
