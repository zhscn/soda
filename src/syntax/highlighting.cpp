#include "syntax/highlighting.hpp"

#include "cpp_lexer/token.hpp"
#include "syntax/syntax_kind.hpp"

#include <algorithm>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

namespace soda {
namespace {

using Categories = std::vector<HighlightKind>;

bool doc_comment(std::string_view text) {
    return text.starts_with("///") || text.starts_with("//!") || text.starts_with("/**") ||
           text.starts_with("/*!");
}

bool declaration_qualifier(std::string_view text) {
    static const std::unordered_set<std::string_view> values{
        "const",   "consteval", "constexpr", "constinit",    "extern",  "inline",
        "mutable", "register",  "static",    "thread_local", "typedef", "volatile",
    };
    return values.contains(text);
}

bool builtin_type(std::string_view text) {
    static const std::unordered_set<std::string_view> values{
        "auto",  "bool", "char", "char8_t", "char16_t", "char32_t", "decltype", "double",
        "float", "int",  "long", "short",   "signed",   "unsigned", "void",     "wchar_t",
    };
    return values.contains(text);
}

bool keyword(std::string_view text) {
    static const std::unordered_set<std::string_view> values{
        "alignas",
        "alignof",
        "and",
        "and_eq",
        "asm",
        "atomic_cancel",
        "atomic_commit",
        "atomic_noexcept",
        "bitand",
        "bitor",
        "break",
        "catch",
        "co_await",
        "co_return",
        "co_yield",
        "compl",
        "concept",
        "const",
        "const_cast",
        "consteval",
        "constexpr",
        "constinit",
        "continue",
        "contract_assert",
        "delete",
        "dynamic_cast",
        "explicit",
        "export",
        "extern",
        "final",
        "friend",
        "goto",
        "import",
        "inline",
        "module",
        "mutable",
        "new",
        "noexcept",
        "not",
        "not_eq",
        "or",
        "or_eq",
        "override",
        "reflexpr",
        "register",
        "reinterpret_cast",
        "requires",
        "sizeof",
        "static",
        "static_assert",
        "static_cast",
        "synchronized",
        "this",
        "thread_local",
        "throw",
        "try",
        "typedef",
        "typeid",
        "typename",
        "using",
        "virtual",
        "volatile",
        "xor",
        "xor_eq",
    };
    return values.contains(text);
}

bool constant(std::string_view text) {
    return text == "false" || text == "nullptr" || text == "true";
}

HighlightKind lexical_highlight(const Analysis& analysis, Token token) {
    switch (token.kind) {
    case TokenKind::LineComment:
    case TokenKind::BlockComment:
        return doc_comment(analysis.text.substring(token.range)) ? HighlightKind::DocComment
                                                                 : HighlightKind::Comment;
    case TokenKind::StringLiteral:
    case TokenKind::RawStringLiteral:
        return HighlightKind::String;
    case TokenKind::CharacterLiteral:
        return HighlightKind::Constant;
    case TokenKind::Number:
        return HighlightKind::Number;
    case TokenKind::Invalid:
        return HighlightKind::Invalid;
    default:
        break;
    }

    if (has_flag(token.flags, LexicalFlags::PreprocessorLine)) {
        return token.kind == TokenKind::Whitespace || token.kind == TokenKind::Newline
                   ? HighlightKind::None
                   : HighlightKind::Preprocessor;
    }
    if (token.kind >= TokenKind::NamespaceKw && token.kind <= TokenKind::OperatorKw) {
        return HighlightKind::Keyword;
    }
    if (token.kind == TokenKind::Identifier) {
        const std::string spelling = analysis.text.substring(token.range);
        if (constant(spelling)) {
            return HighlightKind::Constant;
        }
        if (builtin_type(spelling)) {
            return HighlightKind::Type;
        }
        if (keyword(spelling)) {
            return HighlightKind::Keyword;
        }
    }
    if (is_operator_spelling(token.kind) || token.kind == TokenKind::Less ||
        token.kind == TokenKind::Greater || token.kind == TokenKind::ColonColon ||
        token.kind == TokenKind::Arrow || token.kind == TokenKind::Equals ||
        token.kind == TokenKind::Question) {
        return HighlightKind::Operator;
    }
    switch (token.kind) {
    case TokenKind::LBrace:
    case TokenKind::RBrace:
    case TokenKind::LParen:
    case TokenKind::RParen:
    case TokenKind::LBracket:
    case TokenKind::RBracket:
        return HighlightKind::Bracket;
    case TokenKind::Colon:
    case TokenKind::Comma:
    case TokenKind::Semicolon:
        return HighlightKind::Delimiter;
    default:
        return HighlightKind::None;
    }
}

class Classifier {
public:
    explicit Classifier(const Analysis& analysis)
        : analysis_(analysis), tokens_(analysis.tree.tokens().flatten()),
          categories_(tokens_.size(), HighlightKind::None), previous_(tokens_.size(), none),
          next_(tokens_.size(), none) {}

    Categories run() {
        classify_lexically();
        build_significant_links();
        collect_nodes(analysis_.tree.root());
        collect_declared_names();
        apply_declared_types_and_constants();
        classify_calls_and_properties();
        classify_declarations();
        apply_declared_types_and_constants();
        classify_preprocessor_definitions();
        return std::move(categories_);
    }

private:
    static constexpr std::size_t none = static_cast<std::size_t>(-1);

    std::string spelling(std::size_t index) const {
        return analysis_.text.substring(tokens_[index].range);
    }

    void classify_lexically() {
        for (std::size_t index = 0; index < tokens_.size(); ++index) {
            categories_[index] = lexical_highlight(analysis_, tokens_[index]);
        }
    }

    void build_significant_links() {
        std::size_t prior = none;
        for (std::size_t index = 0; index < tokens_.size(); ++index) {
            previous_[index] = prior;
            if (!is_trivia(tokens_[index].kind) && tokens_[index].kind != TokenKind::EndOfFile) {
                if (prior != none) {
                    next_[prior] = index;
                }
                prior = index;
            }
        }
    }

    void collect_nodes(SyntaxNodeId id) {
        const SyntaxNode& node = analysis_.tree.node(id);
        nodes_.push_back(id);
        for (SyntaxNodeId child : node.children) {
            collect_nodes(child);
        }
    }

    std::size_t first_significant(const SyntaxNode& node) const {
        for (std::size_t index = node.first_token; index < node.end_token; ++index) {
            if (!is_trivia(tokens_[index].kind) && tokens_[index].kind != TokenKind::EndOfFile) {
                return index;
            }
        }
        return none;
    }

    std::size_t next_identifier(std::size_t index, std::size_t end) const {
        for (index = next_[index]; index != none && index < end; index = next_[index]) {
            if (tokens_[index].kind == TokenKind::Identifier) {
                return index;
            }
        }
        return none;
    }

    std::size_t declared_class_name(const SyntaxNode& node, std::size_t keyword_index) const {
        for (std::size_t index = next_[keyword_index]; index != none && index < node.end_token;
             index = next_[index]) {
            if (tokens_[index].kind == TokenKind::LBrace ||
                tokens_[index].kind == TokenKind::Semicolon) {
                break;
            }
            if (tokens_[index].kind == TokenKind::Identifier && !builtin_type(spelling(index)) &&
                !keyword(spelling(index))) {
                return index;
            }
        }
        return none;
    }

    bool enum_body(const SyntaxNode& body) const {
        if (body.kind != SyntaxKind::ClassBody || body.parent == kInvalidNode) {
            return false;
        }
        const SyntaxNode& declaration = analysis_.tree.node(body.parent);
        const std::size_t first = first_significant(declaration);
        return first != none && tokens_[first].kind == TokenKind::EnumKw;
    }

    void collect_declared_names() {
        for (SyntaxNodeId id : nodes_) {
            const SyntaxNode& node = analysis_.tree.node(id);
            const std::size_t first = first_significant(node);
            if (first == none) {
                continue;
            }
            if (node.kind == SyntaxKind::ClassDecl) {
                const std::size_t name = declared_class_name(node, first);
                if (name != none) {
                    type_names_.insert(spelling(name));
                    categories_[name] = HighlightKind::Type;
                }
            } else if (node.kind == SyntaxKind::OpaqueDeclaration && spelling(first) == "typedef") {
                const std::size_t name = last_identifier_before(node, TokenKind::Semicolon);
                if (name != none) {
                    type_names_.insert(spelling(name));
                    categories_[name] = HighlightKind::Type;
                }
            } else if (node.kind == SyntaxKind::OpaqueDeclaration && spelling(first) == "using") {
                const std::size_t name = next_identifier(first, node.end_token);
                if (name != none && next_[name] != none &&
                    tokens_[next_[name]].kind == TokenKind::Equals) {
                    type_names_.insert(spelling(name));
                    categories_[name] = HighlightKind::Type;
                }
            }
            if (node.kind == SyntaxKind::OpaqueDeclaration && node.parent != kInvalidNode &&
                enum_body(analysis_.tree.node(node.parent))) {
                const std::size_t name = first_significant(node);
                if (name != none && tokens_[name].kind == TokenKind::Identifier) {
                    constant_names_.insert(spelling(name));
                    categories_[name] = HighlightKind::Constant;
                }
            }
        }
    }

    std::size_t last_identifier_before(const SyntaxNode& node, TokenKind stop) const {
        std::size_t result = none;
        for (std::size_t index = node.first_token; index < node.end_token; ++index) {
            if (tokens_[index].kind == stop) {
                break;
            }
            if (tokens_[index].kind == TokenKind::Identifier) {
                result = index;
            }
        }
        return result;
    }

    void apply_declared_types_and_constants() {
        for (std::size_t index = 0; index < tokens_.size(); ++index) {
            if (tokens_[index].kind != TokenKind::Identifier ||
                has_flag(tokens_[index].flags, LexicalFlags::PreprocessorLine)) {
                continue;
            }
            const std::string name = spelling(index);
            if (type_names_.contains(name) && categories_[index] == HighlightKind::None) {
                categories_[index] = HighlightKind::Type;
            } else if (constant_names_.contains(name) &&
                       categories_[index] == HighlightKind::None) {
                categories_[index] = HighlightKind::Constant;
            }
        }
    }

    void classify_calls_and_properties() {
        for (std::size_t index = 0; index < tokens_.size(); ++index) {
            if (tokens_[index].kind != TokenKind::Identifier ||
                categories_[index] != HighlightKind::None) {
                continue;
            }
            const std::size_t after = next_[index];
            const std::size_t before = previous_[index];
            if (after != none && tokens_[after].kind == TokenKind::LParen) {
                categories_[index] = HighlightKind::FunctionCall;
            } else if (before != none && (tokens_[before].kind == TokenKind::Period ||
                                          tokens_[before].kind == TokenKind::Arrow)) {
                categories_[index] = HighlightKind::PropertyName;
            }
        }
    }

    std::size_t declarator_before_paren(const SyntaxNode& node) const {
        for (SyntaxNodeId child_id : node.children) {
            const SyntaxNode& child = analysis_.tree.node(child_id);
            if (child.kind != SyntaxKind::ParenGroup) {
                continue;
            }
            const std::size_t before = previous_[child.first_token];
            if (before != none && before >= node.first_token &&
                tokens_[before].kind == TokenKind::Identifier) {
                return before;
            }
        }
        return none;
    }

    bool declaration_like(const SyntaxNode& node, std::size_t declarator) {
        const std::size_t first = first_significant(node);
        if (first == none || declarator == none) {
            return false;
        }
        const std::string first_text = spelling(first);
        if (first_text == "return" || first_text == "co_return" || first_text == "throw" ||
            first_text == "delete") {
            return false;
        }
        bool saw_type = false;
        std::size_t identifiers = 0;
        for (std::size_t index = first; index < declarator; index = next_[index]) {
            if (index == none || index >= node.end_token) {
                break;
            }
            if (tokens_[index].kind == TokenKind::Equals ||
                is_operator_spelling(tokens_[index].kind)) {
                return false;
            }
            if (categories_[index] == HighlightKind::Type ||
                declaration_qualifier(spelling(index))) {
                saw_type = true;
            }
            if (tokens_[index].kind == TokenKind::Identifier &&
                categories_[index] == HighlightKind::None) {
                ++identifiers;
            }
        }
        if (!saw_type && identifiers > 0) {
            const std::size_t candidate = first;
            if (tokens_[candidate].kind == TokenKind::Identifier) {
                type_names_.insert(spelling(candidate));
                categories_[candidate] = HighlightKind::Type;
                saw_type = true;
            }
        }
        return saw_type;
    }

    void classify_parameter_names(const SyntaxNode& function) {
        for (SyntaxNodeId child_id : function.children) {
            const SyntaxNode& child = analysis_.tree.node(child_id);
            if (child.kind != SyntaxKind::ParenGroup || child.end_token <= child.first_token + 1) {
                continue;
            }
            std::size_t segment_start = child.first_token + 1;
            int depth = 0;
            for (std::size_t index = segment_start; index < child.end_token; ++index) {
                const TokenKind kind = tokens_[index].kind;
                depth += kind == TokenKind::LParen || kind == TokenKind::LBracket ||
                                 kind == TokenKind::LBrace
                             ? 1
                             : 0;
                depth -= kind == TokenKind::RParen || kind == TokenKind::RBracket ||
                                 kind == TokenKind::RBrace
                             ? 1
                             : 0;
                if ((kind == TokenKind::Comma && depth == 0) ||
                    (kind == TokenKind::RParen && depth < 0)) {
                    classify_declarator_segment(segment_start, index, HighlightKind::VariableName);
                    segment_start = index + 1;
                }
            }
            break;
        }
    }

    void classify_declarator_segment(std::size_t start, std::size_t end, HighlightKind face) {
        std::size_t candidate = none;
        std::vector<std::size_t> identifiers;
        for (std::size_t index = start; index < end; ++index) {
            if (tokens_[index].kind == TokenKind::Equals) {
                break;
            }
            if (tokens_[index].kind == TokenKind::Identifier &&
                categories_[index] != HighlightKind::Keyword) {
                identifiers.push_back(index);
                candidate = index;
            }
        }
        if (identifiers.size() >= 2) {
            const auto type =
                std::find_if(identifiers.rbegin() + 1, identifiers.rend(), [&](std::size_t index) {
                    return categories_[index] == HighlightKind::None;
                });
            if (type != identifiers.rend()) {
                type_names_.insert(spelling(*type));
                categories_[*type] = HighlightKind::Type;
            }
        }
        if (candidate != none && categories_[candidate] != HighlightKind::Type &&
            categories_[candidate] != HighlightKind::Constant) {
            categories_[candidate] = face;
        }
    }

    void classify_variable_declaration(const SyntaxNode& node, HighlightKind face) {
        const std::size_t first = first_significant(node);
        if (first == none || spelling(first) == "return" || spelling(first) == "goto") {
            return;
        }
        bool declaration =
            categories_[first] == HighlightKind::Type || declaration_qualifier(spelling(first));
        std::size_t identifier_count = 0;
        int angle_depth = 0;
        bool type_expression = tokens_[first].kind == TokenKind::Identifier;
        for (std::size_t index = first; index < node.end_token; index = next_[index]) {
            if (tokens_[index].kind == TokenKind::Equals ||
                tokens_[index].kind == TokenKind::Semicolon ||
                tokens_[index].kind == TokenKind::LParen ||
                (tokens_[index].kind == TokenKind::Comma && angle_depth == 0)) {
                break;
            }
            identifier_count += tokens_[index].kind == TokenKind::Identifier ? 1 : 0;
            angle_depth += tokens_[index].kind == TokenKind::Less ? 1 : 0;
            angle_depth -= tokens_[index].kind == TokenKind::Greater ? 1 : 0;
            type_expression =
                type_expression && (tokens_[index].kind == TokenKind::Identifier ||
                                    tokens_[index].kind == TokenKind::ColonColon ||
                                    tokens_[index].kind == TokenKind::Less ||
                                    tokens_[index].kind == TokenKind::Greater ||
                                    (tokens_[index].kind == TokenKind::Comma && angle_depth > 0));
        }
        declaration = declaration || (type_expression && angle_depth == 0 && identifier_count >= 2);
        if (!declaration) {
            return;
        }
        std::size_t segment_start = first;
        int depth = 0;
        for (std::size_t index = first; index < node.end_token; ++index) {
            const TokenKind kind = tokens_[index].kind;
            depth += kind == TokenKind::LParen || kind == TokenKind::LBracket ||
                             kind == TokenKind::LBrace
                         ? 1
                         : 0;
            depth -= kind == TokenKind::RParen || kind == TokenKind::RBracket ||
                             kind == TokenKind::RBrace
                         ? 1
                         : 0;
            if ((kind == TokenKind::Comma && depth == 0) || kind == TokenKind::Semicolon) {
                classify_declarator_segment(segment_start, index, face);
                segment_start = index + 1;
            }
        }
    }

    void classify_declarations() {
        for (SyntaxNodeId id : nodes_) {
            const SyntaxNode& node = analysis_.tree.node(id);
            if (node.kind == SyntaxKind::FunctionDefinition) {
                const std::size_t name = declarator_before_paren(node);
                if (name != none) {
                    categories_[name] = HighlightKind::FunctionName;
                    classify_parameter_names(node);
                }
                continue;
            }
            if (node.kind != SyntaxKind::OpaqueDeclaration) {
                continue;
            }
            const std::size_t first = first_significant(node);
            if (first == none) {
                continue;
            }
            if (next_[first] != none && tokens_[first].kind == TokenKind::Identifier &&
                tokens_[next_[first]].kind == TokenKind::Colon) {
                categories_[first] = HighlightKind::Label;
                continue;
            }
            if (spelling(first) == "goto") {
                const std::size_t target = next_identifier(first, node.end_token);
                if (target != none) {
                    categories_[target] = HighlightKind::Label;
                }
                continue;
            }
            const std::size_t function = declarator_before_paren(node);
            if (function != none) {
                if (declaration_like(node, function)) {
                    categories_[function] = HighlightKind::FunctionName;
                    classify_parameter_names(node);
                }
                continue;
            }
            if (spelling(first) == "typedef" || spelling(first) == "using" ||
                (node.parent != kInvalidNode && enum_body(analysis_.tree.node(node.parent)))) {
                continue;
            }
            const HighlightKind face =
                node.parent != kInvalidNode &&
                        analysis_.tree.node(node.parent).kind == SyntaxKind::ClassBody
                    ? HighlightKind::PropertyName
                    : HighlightKind::VariableName;
            classify_variable_declaration(node, face);
        }
    }

    void classify_preprocessor_definitions() {
        for (std::size_t index = 0; index < tokens_.size(); ++index) {
            if (tokens_[index].kind != TokenKind::Identifier ||
                !has_flag(tokens_[index].flags, LexicalFlags::PreprocessorLine) ||
                spelling(index) != "define") {
                continue;
            }
            const std::size_t name = next_[index];
            if (name == none || tokens_[name].kind != TokenKind::Identifier ||
                !has_flag(tokens_[name].flags, LexicalFlags::PreprocessorLine)) {
                continue;
            }
            const std::size_t after = next_[name];
            const bool function_like = after != none && tokens_[after].kind == TokenKind::LParen &&
                                       tokens_[name].range.end == tokens_[after].range.start;
            categories_[name] =
                function_like ? HighlightKind::FunctionName : HighlightKind::VariableName;
            if (!function_like) {
                continue;
            }
            for (std::size_t parameter = next_[after];
                 parameter != none && tokens_[parameter].kind != TokenKind::RParen;
                 parameter = next_[parameter]) {
                if (!has_flag(tokens_[parameter].flags, LexicalFlags::PreprocessorLine)) {
                    break;
                }
                if (tokens_[parameter].kind == TokenKind::Identifier) {
                    categories_[parameter] = HighlightKind::VariableName;
                }
            }
        }
    }

    const Analysis& analysis_;
    std::vector<Token> tokens_;
    Categories categories_;
    std::vector<std::size_t> previous_;
    std::vector<std::size_t> next_;
    std::vector<SyntaxNodeId> nodes_;
    std::unordered_set<std::string> type_names_;
    std::unordered_set<std::string> constant_names_;
};

} // namespace

std::vector<HighlightKind> classify_highlights(const Analysis& analysis) {
    return Classifier(analysis).run();
}

} // namespace soda
