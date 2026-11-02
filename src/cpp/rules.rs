use super::{
    AccessIndent, ConstructorInitializers, CppStyle, NamespaceIndentation, PPDirectiveIndent,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ParserOptions {
    pub loop_macros: Vec<String>,
    pub conditional_macros: Vec<String>,
    pub statement_macros: Vec<String>,
    pub namespace_macros: Vec<String>,
    pub attribute_macros: Vec<String>,
    pub whitespace_sensitive_macros: Vec<String>,
    /// Names whose `<` always opens template arguments, clang-format's
    /// TemplateNames, even where an expression would read a comparison.
    pub template_names: Vec<String>,
    pub macro_block_begin: String,
    pub macro_block_end: String,
}

pub use crate::language::WhitespacePolicy;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OperandAlignment {
    None,
    FirstOperand,
    AfterOperator,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExpressionPolicy {
    pub continuation_width: usize,
    pub align_parentheses: bool,
    pub operand_alignment: OperandAlignment,
    pub anchor_ternary_before_operator: bool,
    pub inheritance_before_comma: bool,
}
/// Extern bodies can follow namespace behavior for editor-authored styles.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExternIndentation {
    None,
    Indent,
    FollowNamespace,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StructurePolicy {
    pub namespace: NamespaceIndentation,
    pub extern_body: ExternIndentation,
    pub indent_type_body: bool,
    pub access: AccessIndent,
    /// Signed offset from the ordinary member indentation, not the declaration.
    pub access_offset: isize,
    pub indent_case_labels: bool,
    pub indent_case_body: bool,
    pub indent_case_blocks: bool,
    pub indent_requires_clause: bool,
    pub goto_labels: super::GotoLabelIndent,
    pub lambda_outer_scope: bool,
    pub indent_export_block: bool,
    pub requires_expression_keyword: bool,
    pub brace_indent: super::BraceIndent,
    pub skip_macro_definition_body: bool,
    pub indent_wrapped_function_names: bool,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InitializerLayout {
    Block,
    Continuation,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InitializerPolicy {
    pub width: usize,
    pub layout: InitializerLayout,
    /// A line comment right after the brace is the first element, and the
    /// elements below line up with it; otherwise the list breaks after `{`.
    pub first_comment: bool,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConstructorPolicy {
    pub width: usize,
    pub layout: ConstructorInitializers,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DirectivePolicy {
    pub width: usize,
    pub layout: PPDirectiveIndent,
}

/// Resolved C++ behavior for one document, independent of syntax-tree storage
/// and solver rules. Configuration loading resolves inheritance and defaults.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CppRules {
    pub(crate) enabled: bool,
    pub(crate) whitespace: WhitespacePolicy,
    pub(crate) parser: ParserOptions,
    pub(crate) structure: StructurePolicy,
    pub(crate) expression: ExpressionPolicy,
    pub(crate) initializer: InitializerPolicy,
    pub(crate) constructor: ConstructorPolicy,
    pub(crate) directive: DirectivePolicy,
}
impl CppRules {
    pub fn enabled(&self) -> bool {
        self.enabled
    }
    pub fn whitespace(&self) -> &WhitespacePolicy {
        &self.whitespace
    }
    pub fn parser_options(&self) -> &ParserOptions {
        &self.parser
    }
    pub fn structure(&self) -> &StructurePolicy {
        &self.structure
    }
    pub fn expression(&self) -> &ExpressionPolicy {
        &self.expression
    }
    pub fn initializer(&self) -> &InitializerPolicy {
        &self.initializer
    }
    pub fn constructor(&self) -> &ConstructorPolicy {
        &self.constructor
    }
    pub fn directive(&self) -> &DirectivePolicy {
        &self.directive
    }
}
impl CppStyle {
    /// Validate and resolve editor-authored behavior before editing.
    pub fn compile(&self) -> Result<CppRules, super::StyleError> {
        self.validate()?;
        let w = self.indent_width;
        let cont = self.continuation_indent;
        Ok(CppRules {
            enabled: !self.disable_format,
            whitespace: WhitespacePolicy {
                indent_width: w,
                tab_width: self.tab_width,
                tabs: self.tabs,
            },
            parser: self.parser.clone(),
            structure: StructurePolicy {
                namespace: self.namespace_indentation,
                extern_body: match self.indent_extern_body {
                    Some(true) => ExternIndentation::Indent,
                    Some(false) => ExternIndentation::None,
                    None => ExternIndentation::FollowNamespace,
                },
                indent_type_body: self.indent_type_body,
                access: self.access_indent,
                access_offset: self.access_specifier_offset.saturating_sub(w as isize),
                indent_case_labels: self.indent_case_label,
                indent_case_body: self.indent_case_body,
                indent_case_blocks: self.indent_case_blocks,
                indent_requires_clause: self.indent_requires_clause,
                goto_labels: self.goto_labels,
                lambda_outer_scope: self.lambda_outer_scope,
                indent_export_block: self.indent_export_block,
                requires_expression_keyword: self.requires_expression_keyword,
                brace_indent: self.brace_indent,
                skip_macro_definition_body: self.skip_macro_definition_body,
                indent_wrapped_function_names: self.indent_wrapped_function_names,
            },
            expression: ExpressionPolicy {
                continuation_width: cont,
                align_parentheses: self.align_open_bracket,
                operand_alignment: self.operand_alignment,
                anchor_ternary_before_operator: self.break_before_ternary,
                inheritance_before_comma: self.inheritance_before_comma,
            },
            initializer: InitializerPolicy {
                width: if self.brace_init_continuation {
                    self.braced_initializer_indent.unwrap_or(cont)
                } else {
                    w
                },
                layout: if self.brace_init_continuation {
                    InitializerLayout::Continuation
                } else {
                    InitializerLayout::Block
                },
                first_comment: self.braced_first_comment,
            },
            constructor: ConstructorPolicy {
                width: self.constructor_indent.unwrap_or(cont),
                layout: self.constructor_initializers,
            },
            directive: DirectivePolicy {
                width: self.pp_indent_width.unwrap_or(w),
                layout: self.pp_directive_indent,
            },
        })
    }
}
impl Default for CppRules {
    fn default() -> Self {
        CppStyle::default()
            .compile()
            .expect("valid default C++ style")
    }
}
