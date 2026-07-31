#include "tree_sitter/c_api.h"

#include "document/c_api_internal.hpp"
#include "document/text.hpp"

#include <tree_sitter/api.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

extern "C" const TSLanguage* tree_sitter_json(void);

struct soda_ts_parser {
    TSParser* parser = nullptr;
    TSTree* tree = nullptr;
    const TSLanguage* language = nullptr;
    soda::Text text;
    std::uint32_t document_id = 0;
    std::uint64_t revision = SODA_TREE_SITTER_REVISION_NONE;
    std::thread::id owner = std::this_thread::get_id();
};

struct soda_ts_capture {
    std::string name;
    std::string node_kind;
    std::uint32_t start = 0;
    std::uint32_t end = 0;
    std::uint32_t depth = 0;
};

struct soda_ts_query_result {
    std::vector<soda_ts_capture> captures;
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
        set_error("unknown Tree-sitter failure");
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

void require_owner(const soda_ts_parser& parser) {
    if (parser.owner != std::this_thread::get_id()) {
        throw std::logic_error("Tree-sitter parser used from a non-owning thread");
    }
}

soda_ts_parser& parser_handle(soda_ts_parser* parser) {
    auto& value = require_handle(parser, "Tree-sitter parser");
    require_owner(value);
    return value;
}

const soda_ts_parser& parser_handle(const soda_ts_parser* parser) {
    const auto& value = require_handle(parser, "Tree-sitter parser");
    require_owner(value);
    return value;
}

const TSLanguage* language_by_name(std::string_view name) {
    if (name == "json") {
        return tree_sitter_json();
    }
    throw std::invalid_argument("unknown statically linked Tree-sitter language");
}

struct InputPayload {
    const soda::Text* text = nullptr;
    std::string_view window;
};

const char* read_text(void* payload, std::uint32_t byte_index, TSPoint, std::uint32_t* bytes_read) {
    auto& input = *static_cast<InputPayload*>(payload);
    if (byte_index >= input.text->size_bytes()) {
        *bytes_read = 0;
        return nullptr;
    }
    soda::TextCursor cursor(*input.text, soda::TextOffset{byte_index});
    input.window = cursor.chunk();
    *bytes_read = static_cast<std::uint32_t>(input.window.size());
    return input.window.data();
}

TSTree* parse_text(soda_ts_parser& parser, const soda::Text& text, const TSTree* old_tree) {
    InputPayload payload{.text = &text, .window = {}};
    TSInput input{
        .payload = &payload,
        .read = read_text,
        .encoding = TSInputEncodingUTF8,
        .decode = nullptr,
    };
    TSTree* tree = ts_parser_parse(parser.parser, old_tree, input);
    if (tree == nullptr) {
        throw std::runtime_error("Tree-sitter parse did not produce a tree");
    }
    return tree;
}

TSPoint point_at(const soda::Text& text, std::uint32_t offset) {
    const auto point = text.position(soda::TextOffset{offset});
    return TSPoint{.row = point.line, .column = point.byte_column};
}

void install_tree(soda_ts_parser& parser, TSTree* tree, const soda::DocumentSnapshot& snapshot) {
    ts_tree_delete(parser.tree);
    parser.tree = tree;
    parser.text = snapshot.content();
    parser.document_id = snapshot.document_id();
    parser.revision = snapshot.revision();
}

TSNode root_node(soda_ts_parser& parser) {
    if (parser.tree == nullptr) {
        throw std::logic_error("Tree-sitter parser has no current tree");
    }
    return ts_tree_root_node(parser.tree);
}

std::uint32_t node_depth(TSNode node) {
    std::uint32_t depth = 0;
    for (TSNode parent = ts_node_parent(node); !ts_node_is_null(parent);
         parent = ts_node_parent(parent)) {
        ++depth;
    }
    return depth;
}

const soda_ts_capture& capture_at(const soda_ts_query_result& result, std::uint32_t index) {
    if (index >= result.captures.size()) {
        throw std::out_of_range("Tree-sitter capture index is out of range");
    }
    return result.captures[index];
}

} // namespace

extern "C" {

uint32_t soda_tree_sitter_abi_version(void) {
    return SODA_TREE_SITTER_ABI_VERSION;
}

const char* soda_tree_sitter_last_error(void) {
    return last_error.data();
}

soda_ts_parser* soda_ts_parser_create(const char* language) {
    return guard<soda_ts_parser*>(nullptr, [&] {
        if (language == nullptr) {
            throw std::invalid_argument("Tree-sitter language is null");
        }
        auto* value = new soda_ts_parser;
        value->language = language_by_name(language);
        value->parser = ts_parser_new();
        if (value->parser == nullptr || !ts_parser_set_language(value->parser, value->language)) {
            ts_parser_delete(value->parser);
            delete value;
            throw std::runtime_error("Tree-sitter language is incompatible");
        }
        return value;
    });
}

void soda_ts_parser_destroy(soda_ts_parser* parser) {
    if (parser == nullptr) {
        return;
    }
    if (parser->owner != std::this_thread::get_id()) {
        std::terminate();
    }
    ts_tree_delete(parser->tree);
    ts_parser_delete(parser->parser);
    delete parser;
}

int soda_ts_parser_parse(soda_ts_parser* parser, const soda_snapshot* snapshot) {
    return guard(-1, [&] {
        auto& value = parser_handle(parser);
        const auto& native = soda::abi::unwrap_snapshot(require_handle(snapshot, "snapshot"));
        TSTree* tree = parse_text(value, native.content(), nullptr);
        install_tree(value, tree, native);
        return 0;
    });
}

int soda_ts_parser_apply(soda_ts_parser* parser, const soda_change* change,
                         const soda_snapshot* snapshot) {
    return guard(-1, [&] {
        auto& value = parser_handle(parser);
        const auto& native_change = soda::abi::unwrap_change(require_handle(change, "change"));
        const auto& native_snapshot =
            soda::abi::unwrap_snapshot(require_handle(snapshot, "snapshot"));
        if (value.tree == nullptr || value.document_id != native_snapshot.document_id() ||
            value.revision != native_change.old_revision ||
            native_snapshot.revision() != native_change.new_revision) {
            throw std::logic_error("Tree-sitter incremental parse revision differs");
        }
        soda::Text edited = value.text;
        std::int64_t delta = 0;
        for (const auto& edit : native_change.edits) {
            const auto start = static_cast<std::uint32_t>(
                static_cast<std::int64_t>(edit.old_range.start.value) + delta);
            const auto old_end = static_cast<std::uint32_t>(
                static_cast<std::int64_t>(edit.old_range.end.value) + delta);
            const auto new_end = start + static_cast<std::uint32_t>(edit.new_text.size());
            const TSPoint start_point = point_at(edited, start);
            const TSPoint old_end_point = point_at(edited, old_end);
            soda::Text next = edited.replace(
                soda::TextRange{soda::TextOffset{start}, soda::TextOffset{old_end}}, edit.new_text);
            const TSPoint new_end_point = point_at(next, new_end);
            const TSInputEdit input_edit{
                .start_byte = start,
                .old_end_byte = old_end,
                .new_end_byte = new_end,
                .start_point = start_point,
                .old_end_point = old_end_point,
                .new_end_point = new_end_point,
            };
            ts_tree_edit(value.tree, &input_edit);
            delta +=
                static_cast<std::int64_t>(edit.new_text.size()) -
                static_cast<std::int64_t>(edit.old_range.end.value - edit.old_range.start.value);
            edited = std::move(next);
        }
        TSTree* tree = parse_text(value, native_snapshot.content(), value.tree);
        install_tree(value, tree, native_snapshot);
        return 0;
    });
}

uint32_t soda_ts_parser_document_id(const soda_ts_parser* parser) {
    return guard(std::numeric_limits<std::uint32_t>::max(),
                 [&] { return parser_handle(parser).document_id; });
}

uint64_t soda_ts_parser_revision(const soda_ts_parser* parser) {
    return guard<std::uint64_t>(SODA_TREE_SITTER_REVISION_NONE,
                                [&] { return parser_handle(parser).revision; });
}

const char* soda_ts_parser_root_kind(soda_ts_parser* parser) {
    return guard<const char*>(nullptr,
                              [&] { return ts_node_type(root_node(parser_handle(parser))); });
}

int soda_ts_parser_root_range(soda_ts_parser* parser, uint32_t* start, uint32_t* end) {
    return guard(-1, [&] {
        if (start == nullptr || end == nullptr) {
            throw std::invalid_argument("root range output is null");
        }
        const TSNode root = root_node(parser_handle(parser));
        *start = ts_node_start_byte(root);
        *end = ts_node_end_byte(root);
        return 0;
    });
}

int soda_ts_parser_root_has_error(soda_ts_parser* parser) {
    return guard(-1, [&] { return ts_node_has_error(root_node(parser_handle(parser))) ? 1 : 0; });
}

soda_ts_query_result* soda_ts_parser_query(soda_ts_parser* parser, const char* source,
                                           uint32_t start, uint32_t end) {
    return guard<soda_ts_query_result*>(nullptr, [&] {
        auto& value = parser_handle(parser);
        if (source == nullptr) {
            throw std::invalid_argument("Tree-sitter query source is null");
        }
        if (start > end || end > value.text.size_bytes()) {
            throw std::out_of_range("Tree-sitter query range is invalid");
        }
        uint32_t error_offset = 0;
        TSQueryError error_type = TSQueryErrorNone;
        std::unique_ptr<TSQuery, decltype(&ts_query_delete)> query{
            ts_query_new(value.language, source,
                         static_cast<std::uint32_t>(std::char_traits<char>::length(source)),
                         &error_offset, &error_type),
            ts_query_delete};
        if (!query) {
            throw std::invalid_argument("invalid Tree-sitter query at byte " +
                                        std::to_string(error_offset) + " (error " +
                                        std::to_string(static_cast<int>(error_type)) + ")");
        }
        std::unique_ptr<TSQueryCursor, decltype(&ts_query_cursor_delete)> cursor{
            ts_query_cursor_new(), ts_query_cursor_delete};
        if (!cursor) {
            throw std::runtime_error("Tree-sitter query cursor allocation failed");
        }
        ts_query_cursor_set_byte_range(cursor.get(), start, end);
        ts_query_cursor_exec(cursor.get(), query.get(), root_node(value));
        auto result = std::make_unique<soda_ts_query_result>();
        TSQueryMatch match{};
        uint32_t capture_index = 0;
        while (ts_query_cursor_next_capture(cursor.get(), &match, &capture_index)) {
            const TSQueryCapture capture = match.captures[capture_index];
            uint32_t name_length = 0;
            const char* name =
                ts_query_capture_name_for_id(query.get(), capture.index, &name_length);
            result->captures.push_back(soda_ts_capture{
                .name = std::string(name, name_length),
                .node_kind = ts_node_type(capture.node),
                .start = ts_node_start_byte(capture.node),
                .end = ts_node_end_byte(capture.node),
                .depth = node_depth(capture.node),
            });
        }
        return result.release();
    });
}

void soda_ts_query_result_destroy(soda_ts_query_result* result) {
    delete result;
}

uint32_t soda_ts_query_result_count(const soda_ts_query_result* result) {
    return guard(std::numeric_limits<std::uint32_t>::max(), [&] {
        return static_cast<std::uint32_t>(require_handle(result, "query result").captures.size());
    });
}

const char* soda_ts_query_result_name(const soda_ts_query_result* result, uint32_t index) {
    return guard<const char*>(nullptr, [&] {
        return capture_at(require_handle(result, "query result"), index).name.c_str();
    });
}

const char* soda_ts_query_result_node_kind(const soda_ts_query_result* result, uint32_t index) {
    return guard<const char*>(nullptr, [&] {
        return capture_at(require_handle(result, "query result"), index).node_kind.c_str();
    });
}

int soda_ts_query_result_range(const soda_ts_query_result* result, uint32_t index, uint32_t* start,
                               uint32_t* end) {
    return guard(-1, [&] {
        if (start == nullptr || end == nullptr) {
            throw std::invalid_argument("capture range output is null");
        }
        const auto& capture = capture_at(require_handle(result, "query result"), index);
        *start = capture.start;
        *end = capture.end;
        return 0;
    });
}

uint32_t soda_ts_query_result_depth(const soda_ts_query_result* result, uint32_t index) {
    return guard(std::numeric_limits<std::uint32_t>::max(),
                 [&] { return capture_at(require_handle(result, "query result"), index).depth; });
}

} // extern "C"
