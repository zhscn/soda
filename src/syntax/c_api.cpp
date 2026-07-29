#include "syntax/c_api.h"

#include "document/c_api_internal.hpp"
#include "syntax/analysis.hpp"
#include "syntax/c_api_internal.hpp"
#include "syntax/structure.hpp"
#include "syntax/syntax_kind.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_set>
#include <utility>

static_assert(static_cast<int>(soda::SyntaxKind::TranslationUnit) == SODA_SYNTAX_TRANSLATION_UNIT);
static_assert(static_cast<int>(soda::SyntaxKind::Error) == SODA_SYNTAX_ERROR);

struct soda_cpp_analyzer {
    soda::Analyzer value;
    const soda::Analysis* current = nullptr;
    std::optional<soda::DocumentId> document_id;
    std::unordered_set<soda::SyntaxNodeId> known_nodes;
    const std::thread::id owner = std::this_thread::get_id();
};

namespace {

thread_local std::array<char, 512> last_error{};

void clear_error() noexcept {
    last_error.front() = '\0';
}

void set_error(std::string_view message) noexcept {
    const std::size_t size = std::min(message.size(), last_error.size() - 1);
    std::ranges::copy_n(message.begin(), static_cast<std::ptrdiff_t>(size), last_error.begin());
    last_error[size] = '\0';
}

template <typename Result, typename Operation>
Result guard(Result failure, Operation&& operation) noexcept {
    try {
        clear_error();
        return std::forward<Operation>(operation)();
    } catch (const std::exception& exception) {
        set_error(exception.what());
    } catch (...) {
        set_error("unknown native C++ analysis failure");
    }
    return failure;
}

template <typename Handle> Handle& require_handle(Handle* handle, std::string_view kind) {
    if (handle == nullptr) {
        throw std::invalid_argument(std::string(kind) + " handle is null");
    }
    return *handle;
}

template <typename Handle>
const Handle& require_handle(const Handle* handle, std::string_view kind) {
    if (handle == nullptr) {
        throw std::invalid_argument(std::string(kind) + " handle is null");
    }
    return *handle;
}

void require_owner(const soda_cpp_analyzer& analyzer) {
    if (analyzer.owner != std::this_thread::get_id()) {
        throw std::logic_error("C++ analyzer used from a non-owning thread");
    }
}

void require_owner_or_terminate(const soda_cpp_analyzer& analyzer) noexcept {
    if (analyzer.owner != std::this_thread::get_id()) {
        std::terminate();
    }
}

soda_cpp_analyzer& analyzer_handle(soda_cpp_analyzer* analyzer) {
    auto& handle = require_handle(analyzer, "C++ analyzer");
    require_owner(handle);
    return handle;
}

const soda_cpp_analyzer& analyzer_handle(const soda_cpp_analyzer* analyzer) {
    const auto& handle = require_handle(analyzer, "C++ analyzer");
    require_owner(handle);
    return handle;
}

const soda::Analysis& current_analysis(const soda_cpp_analyzer& analyzer) {
    require_owner(analyzer);
    if (analyzer.current == nullptr) {
        throw std::logic_error("C++ analyzer has no current analysis");
    }
    return *analyzer.current;
}

soda::SyntaxNodeId require_node(const soda_cpp_analyzer& analyzer, std::uint32_t node) {
    if (!analyzer.known_nodes.contains(node)) {
        throw std::out_of_range("syntax node id is invalid or stale");
    }
    return node;
}

void reset_nodes(soda_cpp_analyzer& analyzer) {
    analyzer.known_nodes.clear();
    analyzer.known_nodes.insert(current_analysis(analyzer).tree.root());
}

void require_offset(const soda::Analysis& analysis, std::uint32_t offset) {
    if (offset > analysis.text.size_bytes()) {
        throw std::out_of_range("text offset is out of range");
    }
}

void require_range(const soda::Analysis& analysis, std::uint32_t start, std::uint32_t end) {
    if (start > end) {
        throw std::invalid_argument("range start is greater than range end");
    }
    require_offset(analysis, end);
}

void write_range(soda::TextRange range, std::uint32_t* start, std::uint32_t* end) {
    if (start == nullptr || end == nullptr) {
        throw std::invalid_argument("range output is null");
    }
    *start = range.start.value;
    *end = range.end.value;
}

int identifier_highlight(const soda::Analysis& analysis, soda::Token token) {
    static const std::unordered_set<std::string_view> constants{
        "false",
        "nullptr",
        "true",
    };
    static const std::unordered_set<std::string_view> types{
        "auto",  "bool", "char", "char8_t", "char16_t", "char32_t", "decltype", "double",
        "float", "int",  "long", "short",   "signed",   "unsigned", "void",     "wchar_t",
    };
    static const std::unordered_set<std::string_view> keywords{
        "alignas",     "alignof",       "and",           "and_eq",
        "asm",         "atomic_cancel", "atomic_commit", "atomic_noexcept",
        "bitand",      "bitor",         "break",         "catch",
        "co_await",    "co_return",     "co_yield",      "compl",
        "concept",     "const",         "const_cast",    "consteval",
        "constexpr",   "constinit",     "continue",      "contract_assert",
        "delete",      "dynamic_cast",  "explicit",      "export",
        "extern",      "friend",        "goto",          "import",
        "inline",      "module",        "mutable",       "new",
        "noexcept",    "not",           "not_eq",        "or",
        "or_eq",       "reflexpr",      "register",      "reinterpret_cast",
        "requires",    "sizeof",        "static",        "static_assert",
        "static_cast", "synchronized",  "this",          "thread_local",
        "throw",       "try",           "typedef",       "typeid",
        "typename",    "using",         "virtual",       "volatile",
        "xor",         "xor_eq",
    };
    const std::string identifier = analysis.text.substring(token.range);
    const std::string_view name(identifier);
    if (constants.contains(name)) {
        return SODA_CPP_HIGHLIGHT_CONSTANT;
    }
    if (types.contains(name)) {
        return SODA_CPP_HIGHLIGHT_TYPE;
    }
    if (keywords.contains(name)) {
        return SODA_CPP_HIGHLIGHT_KEYWORD;
    }
    return SODA_CPP_HIGHLIGHT_NONE;
}

int token_highlight(const soda::Analysis& analysis, soda::Token token) {
    using soda::LexicalFlags;
    using soda::TokenKind;

    switch (token.kind) {
    case TokenKind::LineComment:
    case TokenKind::BlockComment:
        return SODA_CPP_HIGHLIGHT_COMMENT;
    case TokenKind::StringLiteral:
    case TokenKind::RawStringLiteral:
        return SODA_CPP_HIGHLIGHT_STRING;
    case TokenKind::CharacterLiteral:
        return SODA_CPP_HIGHLIGHT_CONSTANT;
    case TokenKind::Number:
        return SODA_CPP_HIGHLIGHT_NUMBER;
    case TokenKind::Invalid:
        return SODA_CPP_HIGHLIGHT_INVALID;
    default:
        break;
    }

    if (soda::has_flag(token.flags, LexicalFlags::PreprocessorLine)) {
        return token.kind == TokenKind::Whitespace || token.kind == TokenKind::Newline
                   ? SODA_CPP_HIGHLIGHT_NONE
                   : SODA_CPP_HIGHLIGHT_PREPROCESSOR;
    }

    if (token.kind >= TokenKind::NamespaceKw && token.kind <= TokenKind::OperatorKw) {
        return SODA_CPP_HIGHLIGHT_KEYWORD;
    }
    switch (token.kind) {
    case TokenKind::Identifier:
        return identifier_highlight(analysis, token);
    case TokenKind::LBrace:
    case TokenKind::RBrace:
    case TokenKind::LParen:
    case TokenKind::RParen:
    case TokenKind::LBracket:
    case TokenKind::RBracket:
    case TokenKind::Comma:
    case TokenKind::Semicolon:
        return SODA_CPP_HIGHLIGHT_DELIMITER;
    default:
        return SODA_CPP_HIGHLIGHT_NONE;
    }
}

template <typename Query>
int optional_range(soda_cpp_analyzer* analyzer, std::uint32_t* start, std::uint32_t* end,
                   Query&& query) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        if (start == nullptr || end == nullptr) {
            throw std::invalid_argument("range output is null");
        }
        const std::optional<soda::TextRange> result =
            std::forward<Query>(query)(handle, current_analysis(handle));
        if (!result.has_value()) {
            return 0;
        }
        write_range(*result, start, end);
        return 1;
    });
}

} // namespace

namespace soda::abi {

Analyzer& unwrap_analyzer(soda_cpp_analyzer& analyzer) {
    require_owner(analyzer);
    return analyzer.value;
}

const Analysis& current_analysis(const soda_cpp_analyzer& analyzer) {
    return ::current_analysis(analyzer);
}

const Analysis& resync_analyzer(soda_cpp_analyzer& analyzer, const DocumentSnapshot& snapshot) {
    require_owner(analyzer);
    analyzer.current = &analyzer.value.analyze(snapshot);
    analyzer.document_id = snapshot.document_id();
    reset_nodes(analyzer);
    return *analyzer.current;
}

} // namespace soda::abi

extern "C" {

uint32_t soda_cpp_analysis_abi_version(void) {
    return SODA_CPP_ANALYSIS_ABI_VERSION;
}

const char* soda_cpp_analysis_last_error(void) {
    return last_error.data();
}

const char* soda_syntax_kind_name(int kind) {
    return guard<const char*>(nullptr, [&] {
        if (kind < SODA_SYNTAX_TRANSLATION_UNIT || kind > SODA_SYNTAX_ERROR) {
            throw std::out_of_range("syntax kind is out of range");
        }
        return soda::syntax_kind_name(static_cast<soda::SyntaxKind>(kind)).data();
    });
}

soda_cpp_analyzer* soda_cpp_analyzer_create(void) {
    return guard<soda_cpp_analyzer*>(nullptr, [] { return new soda_cpp_analyzer; });
}

void soda_cpp_analyzer_destroy(soda_cpp_analyzer* analyzer) {
    if (analyzer != nullptr) {
        require_owner_or_terminate(*analyzer);
    }
    delete analyzer;
}

int soda_cpp_analyzer_analyze(soda_cpp_analyzer* analyzer, const soda_snapshot* snapshot) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto& native_snapshot =
            soda::abi::unwrap_snapshot(require_handle(snapshot, "snapshot"));
        (void)soda::abi::resync_analyzer(handle, native_snapshot);
        return 0;
    });
}

int soda_cpp_analyzer_apply(soda_cpp_analyzer* analyzer, const soda_change* change,
                            const soda_snapshot* after) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto& native_change = soda::abi::unwrap_change(require_handle(change, "change"));
        const auto& native_after = soda::abi::unwrap_snapshot(require_handle(after, "snapshot"));
        if (native_change.new_revision != native_after.revision()) {
            throw std::invalid_argument("change and snapshot revisions do not match");
        }
        handle.value.apply(native_change, native_after);
        (void)soda::abi::resync_analyzer(handle, native_after);
        return 0;
    });
}

uint64_t soda_cpp_analyzer_revision(const soda_cpp_analyzer* analyzer) {
    return guard<std::uint64_t>(SODA_CPP_ANALYSIS_REVISION_NONE, [&] {
        return current_analysis(analyzer_handle(analyzer)).revision;
    });
}

uint32_t soda_cpp_analyzer_document_id(const soda_cpp_analyzer* analyzer) {
    return guard<std::uint32_t>(0, [&] {
        const auto& handle = analyzer_handle(analyzer);
        (void)current_analysis(handle);
        return *handle.document_id;
    });
}

uint32_t soda_cpp_analyzer_node_count(const soda_cpp_analyzer* analyzer) {
    return guard<std::uint32_t>(SODA_SYNTAX_NODE_NONE, [&] {
        const std::size_t count = current_analysis(analyzer_handle(analyzer)).tree.node_count();
        if (count > std::numeric_limits<std::uint32_t>::max()) {
            throw std::overflow_error("syntax node count exceeds the ABI range");
        }
        return static_cast<std::uint32_t>(count);
    });
}

uint32_t soda_cpp_analyzer_root(soda_cpp_analyzer* analyzer) {
    return guard<std::uint32_t>(SODA_SYNTAX_NODE_NONE, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto root = current_analysis(handle).tree.root();
        handle.known_nodes.insert(root);
        return root;
    });
}

uint32_t soda_cpp_analyzer_node_at(soda_cpp_analyzer* analyzer, uint32_t offset) {
    return guard<std::uint32_t>(SODA_SYNTAX_NODE_NONE, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto& analysis = current_analysis(handle);
        require_offset(analysis, offset);
        const auto node = analysis.tree.node_at(soda::TextOffset{offset});
        handle.known_nodes.insert(node);
        return node;
    });
}

int soda_cpp_analyzer_node_kind(soda_cpp_analyzer* analyzer, uint32_t node) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        return static_cast<int>(
            current_analysis(handle).tree.node(require_node(handle, node)).kind);
    });
}

int soda_cpp_analyzer_node_range(soda_cpp_analyzer* analyzer, uint32_t node, uint32_t* start,
                                 uint32_t* end) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        write_range(current_analysis(handle).tree.node_range(require_node(handle, node)), start,
                    end);
        return 0;
    });
}

uint32_t soda_cpp_analyzer_node_parent(soda_cpp_analyzer* analyzer, uint32_t node) {
    return guard<std::uint32_t>(SODA_SYNTAX_NODE_NONE, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto parent = current_analysis(handle).tree.node(require_node(handle, node)).parent;
        if (parent != soda::kInvalidNode) {
            handle.known_nodes.insert(parent);
        }
        return parent;
    });
}

uint32_t soda_cpp_analyzer_node_child_count(soda_cpp_analyzer* analyzer, uint32_t node) {
    return guard<std::uint32_t>(SODA_SYNTAX_NODE_NONE, [&] {
        auto& handle = analyzer_handle(analyzer);
        const std::size_t count =
            current_analysis(handle).tree.node(require_node(handle, node)).children.size();
        if (count > std::numeric_limits<std::uint32_t>::max()) {
            throw std::overflow_error("syntax child count exceeds the ABI range");
        }
        return static_cast<std::uint32_t>(count);
    });
}

uint32_t soda_cpp_analyzer_node_child(soda_cpp_analyzer* analyzer, uint32_t node,
                                      uint32_t child_index) {
    return guard<std::uint32_t>(SODA_SYNTAX_NODE_NONE, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto& children =
            current_analysis(handle).tree.node(require_node(handle, node)).children;
        if (child_index >= children.size()) {
            throw std::out_of_range("syntax child index is out of range");
        }
        const auto child = children[child_index];
        handle.known_nodes.insert(child);
        return child;
    });
}

int soda_cpp_analyzer_node_incomplete(soda_cpp_analyzer* analyzer, uint32_t node) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        return current_analysis(handle).tree.node(require_node(handle, node)).incomplete ? 1 : 0;
    });
}

uint32_t soda_cpp_analyzer_highlight_count(const soda_cpp_analyzer* analyzer) {
    return guard<std::uint32_t>(SODA_SYNTAX_NODE_NONE, [&] {
        const std::size_t count = current_analysis(analyzer_handle(analyzer)).tree.tokens().size();
        if (count > std::numeric_limits<std::uint32_t>::max()) {
            throw std::overflow_error("highlight token count exceeds the ABI range");
        }
        return static_cast<std::uint32_t>(count);
    });
}

int soda_cpp_analyzer_highlight_at(soda_cpp_analyzer* analyzer, uint32_t token_index,
                                   uint32_t* start, uint32_t* end) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto& analysis = current_analysis(handle);
        const auto& tokens = analysis.tree.tokens();
        if (token_index >= tokens.size()) {
            throw std::out_of_range("highlight token index is out of range");
        }
        const soda::Token token = tokens[token_index];
        write_range(token.range, start, end);
        return token_highlight(analysis, token);
    });
}

int soda_cpp_analyzer_sexp_forward(soda_cpp_analyzer* analyzer, uint32_t from, uint32_t* start,
                                   uint32_t* end) {
    return optional_range(analyzer, start, end, [&](auto&, const soda::Analysis& analysis) {
        require_offset(analysis, from);
        return soda::sexp_forward(analysis.tree, soda::TextOffset{from});
    });
}

int soda_cpp_analyzer_sexp_backward(soda_cpp_analyzer* analyzer, uint32_t from, uint32_t* start,
                                    uint32_t* end) {
    return optional_range(analyzer, start, end, [&](auto&, const soda::Analysis& analysis) {
        require_offset(analysis, from);
        return soda::sexp_backward(analysis.tree, soda::TextOffset{from});
    });
}

int soda_cpp_analyzer_enclosing_list(soda_cpp_analyzer* analyzer, uint32_t offset, uint32_t* start,
                                     uint32_t* end) {
    return optional_range(analyzer, start, end, [&](auto&, const soda::Analysis& analysis) {
        require_offset(analysis, offset);
        return soda::enclosing_list(analysis.tree, soda::TextOffset{offset});
    });
}

int soda_cpp_analyzer_matching_bracket_range(soda_cpp_analyzer* analyzer, uint32_t offset,
                                             uint32_t* start, uint32_t* end) {
    return optional_range(analyzer, start, end, [&](auto&, const soda::Analysis& analysis) {
        require_offset(analysis, offset);
        return soda::matching_bracket_range(analysis.tree, soda::TextOffset{offset});
    });
}

int soda_cpp_analyzer_expand_selection(soda_cpp_analyzer* analyzer, uint32_t selection_start,
                                       uint32_t selection_end, uint32_t* start, uint32_t* end) {
    return optional_range(analyzer, start, end, [&](auto&, const soda::Analysis& analysis) {
        require_range(analysis, selection_start, selection_end);
        return soda::expand_selection(analysis.tree,
                                      soda::make_range(selection_start, selection_end));
    });
}

int soda_cpp_analyzer_soft_kill_end(soda_cpp_analyzer* analyzer, uint32_t from, uint32_t* start,
                                    uint32_t* end) {
    return guard(-1, [&] {
        auto& handle = analyzer_handle(analyzer);
        const auto& analysis = current_analysis(handle);
        require_offset(analysis, from);
        write_range(soda::soft_kill_end(analysis.tree, analysis.text, soda::TextOffset{from}),
                    start, end);
        return 0;
    });
}

} // extern "C"
