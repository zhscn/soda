//! TextMate scope names to highlight categories. A scope matches the longest
//! dotted prefix in the table; a token takes the category of its innermost
//! scope that has one.
use super::Category;

const TABLE: &[(&str, Category)] = &[
    ("comment", Category::Comment),
    ("comment.line.documentation", Category::CommentDoc),
    ("comment.block.documentation", Category::CommentDoc),
    ("string", Category::String),
    ("markup.raw", Category::String),
    ("markup.inline.raw", Category::String),
    ("constant.character.escape", Category::Escape),
    ("constant.numeric", Category::Number),
    ("constant.language", Category::ConstantBuiltin),
    ("constant.other", Category::Constant),
    ("support.constant", Category::Constant),
    ("variable.other.constant", Category::Constant),
    ("variable.language", Category::Constant),
    ("keyword", Category::Keyword),
    ("storage", Category::Keyword),
    ("keyword.operator", Category::Operator),
    ("entity.name.type", Category::Type),
    ("entity.name.class", Category::Type),
    ("entity.name.struct", Category::Type),
    ("entity.name.enum", Category::Type),
    ("entity.name.interface", Category::Type),
    ("entity.name.trait", Category::Type),
    ("entity.other.inherited-class", Category::Type),
    ("support.type", Category::Type),
    ("support.type.primitive", Category::TypeBuiltin),
    ("support.type.builtin", Category::TypeBuiltin),
    ("support.class", Category::Type),
    ("storage.type.primitive", Category::TypeBuiltin),
    ("storage.type.numeric", Category::TypeBuiltin),
    ("storage.type.boolean", Category::TypeBuiltin),
    ("storage.type.string", Category::TypeBuiltin),
    // Most grammars name calls and definitions alike; semantic tokens
    // tell them apart where a server gives them.
    ("entity.name.function", Category::Function),
    ("entity.name.function.call", Category::FunctionCall),
    ("meta.function-call.generic", Category::FunctionCall),
    ("support.function", Category::Function),
    ("support.function.builtin", Category::FunctionBuiltin),
    (
        "entity.name.function.support.builtin",
        Category::FunctionBuiltin,
    ),
    ("variable.other.property", Category::Property),
    ("variable.other.member", Category::Property),
    ("variable.other.object.property", Category::Property),
    ("support.variable.property", Category::Property),
    ("variable.parameter", Category::Parameter),
    ("entity.name.namespace", Category::Namespace),
    ("entity.name.module", Category::Namespace),
    ("meta.preprocessor", Category::Macro),
    ("entity.name.function.preprocessor", Category::Macro),
    ("entity.name.function.macro", Category::Macro),
    ("support.function.macro", Category::Macro),
    ("meta.attribute", Category::Macro),
    ("entity.name.tag", Category::Tag),
    ("entity.other.attribute-name", Category::Attribute),
    ("markup.heading", Category::Heading),
    ("entity.name.section", Category::Heading),
    ("markup.italic", Category::Emphasis),
    ("markup.bold", Category::Strong),
    ("markup.underline.link", Category::Link),
    ("string.other.link", Category::Link),
    ("markup.inserted", Category::Inserted),
    ("markup.deleted", Category::Deleted),
    ("markup.changed", Category::Changed),
    ("invalid", Category::Invalid),
];

/// The category of one scope name, by its longest listed dotted prefix.
pub(super) fn category(scope: &str) -> Option<Category> {
    let mut name = scope;
    loop {
        if let Some((_, category)) = TABLE.iter().find(|(prefix, _)| *prefix == name) {
            return Some(*category);
        }
        name = &name[..name.rfind('.')?];
    }
}

/// The category of a `name` attribute, which may list several scopes from
/// outer to inner.
pub(super) fn categorize(names: &str) -> Option<Category> {
    names.split_whitespace().rev().find_map(category)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn longest_prefix_wins_and_inner_scopes_come_first() {
        assert_eq!(
            category("keyword.operator.assignment.rust"),
            Some(Category::Operator)
        );
        assert_eq!(category("keyword.control.rust"), Some(Category::Keyword));
        assert_eq!(
            category("storage.type.primitive.rust"),
            Some(Category::TypeBuiltin)
        );
        assert_eq!(
            category("comment.line.documentation.rust"),
            Some(Category::CommentDoc)
        );
        assert_eq!(category("punctuation.definition.string"), None);
        assert_eq!(
            categorize("string.quoted.double constant.character.escape.rust"),
            Some(Category::Escape)
        );
        assert_eq!(categorize("meta.block punctuation.x"), None);
    }
}
