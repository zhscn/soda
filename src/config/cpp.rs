//! Maps effective clang-format values to C++ behavior. Syntax positions and
//! solver-specific offsets are resolved by the language service at query time.
use super::{
    ConfigError,
    value::{boolean, choice, integer, size, string, width_or_default},
};
use crate::cpp::{
    AccessIndent, BraceIndent, ConstructorInitializers, CppRules, ExternIndentation,
    InitializerLayout, NamespaceIndentation, PPDirectiveIndent, TabPolicy,
};
use serde_json::{Map, Value};
use std::num::NonZeroUsize;

pub(super) fn to_rules(v: &Map<String, Value>, doc: usize) -> Result<CppRules, ConfigError> {
    let mut policy = CppRules::default();
    macro_rules! get {
        ($key:literal) => {
            v.get($key).expect("complete preset base")
        };
    }
    policy.whitespace.indent_width = size(get!("IndentWidth"), doc, "IndentWidth")?;
    policy.expression.continuation_width = size(
        get!("ContinuationIndentWidth"),
        doc,
        "ContinuationIndentWidth",
    )?;
    policy.whitespace.tab_width = NonZeroUsize::new(size(get!("TabWidth"), doc, "TabWidth")?)
        .ok_or_else(|| ConfigError::key(doc, "TabWidth", "must be greater than zero"))?;
    policy.enabled = !boolean(get!("DisableFormat"), doc, "DisableFormat")?;
    policy.whitespace.tabs = match choice(
        get!("UseTab"),
        doc,
        "UseTab",
        &[
            "Never",
            "ForIndentation",
            "ForContinuationAndIndentation",
            "AlignWithSpaces",
            "Always",
            "true",
            "false",
        ],
    )? {
        "Never" | "false" => TabPolicy::Never,
        "ForIndentation" => TabPolicy::ForIndentation,
        "ForContinuationAndIndentation" => TabPolicy::ForContinuationAndIndentation,
        "AlignWithSpaces" => TabPolicy::AlignWithSpaces,
        _ => TabPolicy::Always,
    };
    policy.structure.namespace = match choice(
        get!("NamespaceIndentation"),
        doc,
        "NamespaceIndentation",
        &["None", "Inner", "All"],
    )? {
        "None" => NamespaceIndentation::None,
        "Inner" => NamespaceIndentation::Inner,
        _ => NamespaceIndentation::All,
    };
    policy.structure.access = match get!("IndentAccessModifiers") {
        value if boolean(value, doc, "IndentAccessModifiers").is_ok() => {
            if boolean(value, doc, "IndentAccessModifiers")? {
                AccessIndent::Always
            } else {
                AccessIndent::Never
            }
        }
        value => match choice(
            value,
            doc,
            "IndentAccessModifiers",
            &["Never", "Always", "AfterFirstAccessModifier"],
        )? {
            "Never" => AccessIndent::Never,
            "Always" => AccessIndent::Always,
            _ => AccessIndent::AfterFirstAccessModifier,
        },
    };
    let offset = integer(get!("AccessModifierOffset"), doc, "AccessModifierOffset")?;
    let offset = isize::try_from(offset).map_err(|_| {
        ConfigError::key(
            doc,
            "AccessModifierOffset",
            "offset is outside the supported range",
        )
    })?;
    crate::cpp::validate_offset(offset)
        .map_err(|message| ConfigError::key(doc, "AccessModifierOffset", message))?;
    policy.structure.access_offset = offset;
    policy.structure.indent_case_labels =
        boolean(get!("IndentCaseLabels"), doc, "IndentCaseLabels")?;
    policy.structure.indent_case_blocks =
        boolean(get!("IndentCaseBlocks"), doc, "IndentCaseBlocks")?;
    policy.structure.indent_requires_clause =
        boolean(get!("IndentRequiresClause"), doc, "IndentRequiresClause")?;
    policy.structure.goto_labels = match choice(
        get!("IndentGotoLabels"),
        doc,
        "IndentGotoLabels",
        &[
            "NoIndent",
            "OuterIndent",
            "InnerIndent",
            "HalfIndent",
            "true",
            "false",
        ],
    )? {
        "NoIndent" | "false" => crate::cpp::GotoLabelIndent::None,
        "InnerIndent" => crate::cpp::GotoLabelIndent::Inner,
        "HalfIndent" => crate::cpp::GotoLabelIndent::Half,
        _ => crate::cpp::GotoLabelIndent::Outer,
    };
    policy.structure.lambda_outer_scope = choice(
        get!("LambdaBodyIndentation"),
        doc,
        "LambdaBodyIndentation",
        &["Signature", "OuterScope"],
    )? == "OuterScope";
    policy.structure.requires_expression_keyword = choice(
        get!("RequiresExpressionIndentation"),
        doc,
        "RequiresExpressionIndentation",
        &["OuterScope", "Keyword"],
    )? == "Keyword";
    policy.structure.skip_macro_definition_body = boolean(
        get!("SkipMacroDefinitionBody"),
        doc,
        "SkipMacroDefinitionBody",
    )?;
    policy.structure.indent_export_block =
        boolean(get!("IndentExportBlock"), doc, "IndentExportBlock")?;
    policy.structure.indent_wrapped_function_names = boolean(
        get!("IndentWrappedFunctionNames"),
        doc,
        "IndentWrappedFunctionNames",
    )?;
    policy.expression.anchor_ternary_before_operator = boolean(
        get!("BreakBeforeTernaryOperators"),
        doc,
        "BreakBeforeTernaryOperators",
    )?;
    policy.expression.operand_alignment = match get!("AlignOperands") {
        value if boolean(value, doc, "AlignOperands").is_ok() => {
            if boolean(value, doc, "AlignOperands")? {
                crate::cpp::OperandAlignment::FirstOperand
            } else {
                crate::cpp::OperandAlignment::None
            }
        }
        value => match choice(
            value,
            doc,
            "AlignOperands",
            &["DontAlign", "Align", "AlignAfterOperator"],
        )? {
            "DontAlign" => crate::cpp::OperandAlignment::None,
            "Align" => crate::cpp::OperandAlignment::FirstOperand,
            _ => crate::cpp::OperandAlignment::AfterOperator,
        },
    };
    policy.expression.align_parentheses = match get!("AlignAfterOpenBracket") {
        v if boolean(v, doc, "AlignAfterOpenBracket").is_ok() => {
            boolean(v, doc, "AlignAfterOpenBracket")?
        }
        v => {
            choice(
                v,
                doc,
                "AlignAfterOpenBracket",
                &["Align", "DontAlign", "AlwaysBreak", "BlockIndent"],
            )? != "DontAlign"
        }
    };
    // The old `true` is AlignFirstComment.
    let (initializer_continuation, first_comment) = match get!("Cpp11BracedListStyle") {
        v if boolean(v, doc, "Cpp11BracedListStyle").is_ok() => {
            (boolean(v, doc, "Cpp11BracedListStyle")?, true)
        }
        v => {
            let layout = choice(
                v,
                doc,
                "Cpp11BracedListStyle",
                &["Block", "FunctionCall", "AlignFirstComment"],
            )?;
            (layout != "Block", layout != "FunctionCall")
        }
    };
    let initializer_width = width_or_default(
        get!("BracedInitializerIndentWidth"),
        doc,
        "BracedInitializerIndentWidth",
    )?;
    policy.constructor.width = size(
        get!("ConstructorInitializerIndentWidth"),
        doc,
        "ConstructorInitializerIndentWidth",
    )?;
    policy.constructor.layout = match choice(
        get!("BreakConstructorInitializers"),
        doc,
        "BreakConstructorInitializers",
        &["BeforeColon", "BeforeComma", "AfterColon", "AfterComma"],
    )? {
        "BeforeComma" => ConstructorInitializers::AlignWithColon,
        _ => ConstructorInitializers::AlignFirstInitializer,
    };
    policy.directive.layout = match choice(
        get!("IndentPPDirectives"),
        doc,
        "IndentPPDirectives",
        &["None", "AfterHash", "BeforeHash", "Leave"],
    )? {
        "None" => PPDirectiveIndent::None,
        "AfterHash" => PPDirectiveIndent::AfterHash,
        "Leave" => PPDirectiveIndent::Leave,
        _ => PPDirectiveIndent::BeforeHash,
    };
    policy.directive.width = width_or_default(get!("PPIndentWidth"), doc, "PPIndentWidth")?
        .unwrap_or(policy.whitespace.indent_width);
    let indent_extern_body = match choice(
        get!("IndentExternBlock"),
        doc,
        "IndentExternBlock",
        &["NoIndent", "Indent", "AfterExternBlock", "true", "false"],
    )? {
        "NoIndent" | "false" => false,
        "Indent" | "true" => true,
        _ => match choice(
            get!("BreakBeforeBraces"),
            doc,
            "BreakBeforeBraces",
            &[
                "Attach",
                "Linux",
                "Mozilla",
                "Stroustrup",
                "Allman",
                "Whitesmiths",
                "GNU",
                "WebKit",
                "Custom",
            ],
        )? {
            "Custom" => boolean(
                &v["BraceWrapping"]["AfterExternBlock"],
                doc,
                "BraceWrapping.AfterExternBlock",
            )?,
            "Mozilla" | "Allman" | "Whitesmiths" | "GNU" => true,
            _ => false,
        },
    };
    // GNU indents the braces of control statements, as IndentBraces does
    // for a custom style; Whitesmiths those of every block.
    policy.structure.brace_indent = match get!("BreakBeforeBraces").as_str() {
        Some("GNU") => BraceIndent::Control,
        Some("Whitesmiths") => BraceIndent::All,
        Some("Custom")
            if boolean(
                &v["BraceWrapping"]["IndentBraces"],
                doc,
                "BraceWrapping.IndentBraces",
            )? =>
        {
            BraceIndent::Control
        }
        _ => BraceIndent::None,
    };
    policy.structure.extern_body = if indent_extern_body {
        ExternIndentation::Indent
    } else {
        ExternIndentation::None
    };
    policy.initializer.first_comment = first_comment;
    policy.initializer.layout = if initializer_continuation {
        InitializerLayout::Continuation
    } else {
        InitializerLayout::Block
    };
    policy.initializer.width = if initializer_continuation {
        initializer_width.unwrap_or(policy.expression.continuation_width)
    } else {
        policy.whitespace.indent_width
    };
    for (key, list) in [
        ("ForEachMacros", &mut policy.parser.loop_macros),
        ("IfMacros", &mut policy.parser.conditional_macros),
        ("StatementMacros", &mut policy.parser.statement_macros),
        ("NamespaceMacros", &mut policy.parser.namespace_macros),
        ("AttributeMacros", &mut policy.parser.attribute_macros),
        (
            "WhitespaceSensitiveMacros",
            &mut policy.parser.whitespace_sensitive_macros,
        ),
        ("TemplateNames", &mut policy.parser.template_names),
    ] {
        if let Some(value) = v.get(key) {
            let values = value
                .as_array()
                .ok_or_else(|| ConfigError::key(doc, key, "expected a sequence of macro names"))?;
            for value in values {
                let name = string(value, doc, key)?;
                if name.is_empty()
                    || !name.bytes().enumerate().all(|(i, b)| {
                        b.is_ascii_alphabetic() || b == b'_' || (i > 0 && b.is_ascii_digit())
                    })
                {
                    return Err(ConfigError::key(
                        doc,
                        key,
                        "expected C++ identifier spellings",
                    ));
                }
                list.push(name.into());
            }
            list.sort();
            list.dedup();
        }
    }
    // A function-like macro that clang-format's Macros expands to the head
    // of a loop or an `if` works as one, as ForEachMacros and IfMacros do.
    if let Some(definitions) = v.get("Macros").and_then(Value::as_array) {
        for definition in definitions {
            let definition = string(definition, doc, "Macros")?;
            if let Some((name, control)) = control_macro(definition) {
                if control == "if" {
                    policy.parser.conditional_macros.push(name.into());
                } else {
                    policy.parser.loop_macros.push(name.into());
                }
            }
        }
        for list in [
            &mut policy.parser.loop_macros,
            &mut policy.parser.conditional_macros,
        ] {
            list.sort();
            list.dedup();
        }
    }
    for (key, pattern) in [
        ("MacroBlockBegin", &mut policy.parser.macro_block_begin),
        ("MacroBlockEnd", &mut policy.parser.macro_block_end),
    ] {
        *pattern = string(v.get(key).expect("complete preset base"), doc, key)?.into();
        if !pattern.is_empty() {
            regex::Regex::new(pattern)
                .map_err(|error| ConfigError::key(doc, key, error.to_string()))?;
        }
    }
    Ok(policy)
}

/// The name of a function-like macro definition, `NAME(params)=expansion`,
/// whose expansion starts with `for`, `while` or `if`, and that keyword.
pub(super) fn control_macro(definition: &str) -> Option<(&str, &str)> {
    let (head, expansion) = definition.split_once('=')?;
    let (name, _) = head.split_once('(')?;
    let name = name.trim();
    let identifier = !name.is_empty()
        && name
            .bytes()
            .enumerate()
            .all(|(i, b)| b.is_ascii_alphabetic() || b == b'_' || (i > 0 && b.is_ascii_digit()));
    let keyword = expansion
        .trim_start()
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .next()?;
    (identifier && matches!(keyword, "for" | "while" | "if")).then_some((name, keyword))
}
