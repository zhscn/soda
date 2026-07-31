#include "tree_sitter/c_api.h"

#include "document/c_api_internal.hpp"
#include "document/text.hpp"

#include <tree_sitter/api.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif
#endif

#ifndef SODA_TREE_SITTER_INSTALL_LIBDIR
#define SODA_TREE_SITTER_INSTALL_LIBDIR "lib"
#endif

#ifndef SODA_TREE_SITTER_INSTALL_DATADIR
#define SODA_TREE_SITTER_INSTALL_DATADIR "share"
#endif

struct soda_ts_parser {
    TSParser* parser = nullptr;
    TSTree* tree = nullptr;
    const TSLanguage* language = nullptr;
    void* language_library = nullptr;
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

struct soda_ts_query {
    TSQuery* query = nullptr;
    const TSLanguage* language = nullptr;
    std::thread::id owner = std::this_thread::get_id();
};

namespace {

thread_local std::array<char, 512> last_error{};
thread_local std::string last_query_source;

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

std::string platform_library_name(std::string_view language, bool prefix) {
#if defined(_WIN32)
    (void)prefix;
    return "tree-sitter-" + std::string(language) + ".dll";
#elif defined(__APPLE__)
    return (prefix ? "lib" : "") + std::string("tree-sitter-") + std::string(language) + ".dylib";
#else
    return (prefix ? "lib" : "") + std::string("tree-sitter-") + std::string(language) + ".so";
#endif
}

char path_list_separator() {
#if defined(_WIN32)
    return ';';
#else
    return ':';
#endif
}

std::optional<std::filesystem::path> executable_path() {
#if defined(_WIN32)
    std::array<char, 32768> buffer{};
    const DWORD length =
        GetModuleFileNameA(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length == buffer.size()) {
        return std::nullopt;
    }
    return std::filesystem::path(std::string_view(buffer.data(), static_cast<std::size_t>(length)));
#elif defined(__APPLE__)
    std::uint32_t size = 0;
    (void)_NSGetExecutablePath(nullptr, &size);
    std::string buffer(size, '\0');
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
        return std::nullopt;
    }
    buffer.resize(std::char_traits<char>::length(buffer.c_str()));
    return std::filesystem::weakly_canonical(buffer);
#else
    std::array<char, 4096> buffer{};
    const auto length = readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
    if (length < 0) {
        return std::nullopt;
    }
    return std::filesystem::path(std::string_view(buffer.data(), static_cast<std::size_t>(length)));
#endif
}

void* open_library(const std::filesystem::path& path) {
#if defined(_WIN32)
    return static_cast<void*>(LoadLibraryA(path.string().c_str()));
#else
    return dlopen(path.string().c_str(), RTLD_NOW | RTLD_LOCAL);
#endif
}

void close_library(void* library) noexcept {
#if defined(_WIN32)
    if (library != nullptr) {
        (void)FreeLibrary(static_cast<HMODULE>(library));
    }
#else
    if (library != nullptr) {
        (void)dlclose(library);
    }
#endif
}

void* library_symbol(void* library, const char* symbol) {
#if defined(_WIN32)
    return reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(library), symbol));
#else
    (void)dlerror();
    return dlsym(library, symbol);
#endif
}

std::string library_error() {
#if defined(_WIN32)
    return "dynamic library error " + std::to_string(GetLastError());
#else
    const char* error = dlerror();
    return error == nullptr ? "unknown dynamic library error" : error;
#endif
}

std::string language_environment_name(std::string_view language) {
    std::string result = "SODA_TREE_SITTER_";
    for (const char character : language) {
        if (character == '-') {
            result.push_back('_');
        } else {
            result.push_back(
                static_cast<char>(std::toupper(static_cast<unsigned char>(character))));
        }
    }
    result += "_LIBRARY";
    return result;
}

bool valid_component(std::string_view value) {
    return !value.empty() && std::ranges::all_of(value, [](unsigned char character) {
        return std::isalnum(character) != 0 || character == '_' || character == '-';
    });
}

std::vector<std::filesystem::path> language_candidates(std::string_view language,
                                                       std::string_view override_library) {
    std::vector<std::filesystem::path> candidates;
    if (!override_library.empty()) {
        candidates.emplace_back(override_library);
        return candidates;
    }
    const std::string environment_name = language_environment_name(language);
    if (const char* configured = std::getenv(environment_name.c_str());
        configured != nullptr && configured[0] != '\0') {
        candidates.emplace_back(configured);
        return candidates;
    }
    const std::array names{
        platform_library_name(language, true),
        platform_library_name(language, false),
    };
    if (const char* search_path = std::getenv("SODA_TREE_SITTER_GRAMMAR_PATH");
        search_path != nullptr) {
        std::string_view remaining(search_path);
        while (!remaining.empty()) {
            const auto separator = remaining.find(path_list_separator());
            const std::string_view directory = remaining.substr(0, separator);
            if (!directory.empty()) {
                for (const auto& name : names) {
                    candidates.emplace_back(std::filesystem::path(directory) / name);
                }
            }
            if (separator == std::string_view::npos) {
                break;
            }
            remaining.remove_prefix(separator + 1);
        }
    }
    if (const auto executable = executable_path(); executable.has_value()) {
        const auto directory = executable->parent_path();
        for (const auto& name : names) {
            candidates.emplace_back(directory / name);
            candidates.emplace_back(directory.parent_path() / SODA_TREE_SITTER_INSTALL_LIBDIR /
                                    "soda" / "grammars" / name);
        }
    }
    for (const auto& name : names) {
        candidates.emplace_back(name);
    }
    return candidates;
}

struct LoadedLanguage {
    void* library = nullptr;
    const TSLanguage* language = nullptr;
};

LoadedLanguage load_language(std::string_view name, std::string_view override_library,
                             std::string_view override_symbol) {
    if (!valid_component(name)) {
        throw std::invalid_argument("Tree-sitter language name is invalid");
    }
    std::string symbol =
        override_symbol.empty() ? "tree_sitter_" + std::string(name) : std::string(override_symbol);
    std::ranges::replace(symbol, '-', '_');
    std::string failures;
    for (const auto& candidate : language_candidates(name, override_library)) {
        void* library = open_library(candidate);
        if (library == nullptr) {
            if (!failures.empty()) {
                failures += "; ";
            }
            failures += candidate.string() + ": " + library_error();
            continue;
        }
        using LanguageFunction = const TSLanguage* (*)();
        auto* function =
            reinterpret_cast<LanguageFunction>(library_symbol(library, symbol.c_str()));
        if (function == nullptr) {
            const std::string error = library_error();
            close_library(library);
            std::string message = candidate.string();
            message += " does not export ";
            message += symbol;
            message += ": ";
            message += error;
            throw std::runtime_error(message);
        }
        const TSLanguage* language = function();
        if (language == nullptr) {
            close_library(library);
            throw std::runtime_error(candidate.string() + " returned a null TSLanguage");
        }
        return {.library = library, .language = language};
    }
    throw std::runtime_error("unable to load Tree-sitter grammar " + std::string(name) +
                             (failures.empty() ? std::string{} : ": " + failures));
}

std::vector<std::filesystem::path> query_candidates(std::string_view language,
                                                    std::string_view query_name) {
    const std::filesystem::path relative =
        std::filesystem::path(language) / (std::string(query_name) + ".scm");
    std::vector<std::filesystem::path> candidates;
    if (const char* search_path = std::getenv("SODA_TREE_SITTER_QUERY_PATH");
        search_path != nullptr) {
        std::string_view remaining(search_path);
        while (!remaining.empty()) {
            const auto separator = remaining.find(path_list_separator());
            const std::string_view directory = remaining.substr(0, separator);
            if (!directory.empty()) {
                candidates.emplace_back(std::filesystem::path(directory) / relative);
            }
            if (separator == std::string_view::npos) {
                break;
            }
            remaining.remove_prefix(separator + 1);
        }
    }
    if (const auto executable = executable_path(); executable.has_value()) {
        const auto directory = executable->parent_path();
        candidates.emplace_back(directory / "queries" / relative);
        candidates.emplace_back(directory.parent_path() / SODA_TREE_SITTER_INSTALL_DATADIR /
                                "soda" / "queries" / relative);
    }
    return candidates;
}

std::string read_query_source(std::string_view language, std::string_view query_name) {
    if (!valid_component(language) || !valid_component(query_name)) {
        throw std::invalid_argument("Tree-sitter query resource name is invalid");
    }
    std::string searched;
    for (const auto& candidate : query_candidates(language, query_name)) {
        std::ifstream stream(candidate, std::ios::binary);
        if (!stream) {
            if (!searched.empty()) {
                searched += ", ";
            }
            searched += candidate.string();
            continue;
        }
        std::string source{std::istreambuf_iterator<char>(stream),
                           std::istreambuf_iterator<char>()};
        if (stream.bad()) {
            throw std::runtime_error("cannot read Tree-sitter query " + candidate.string());
        }
        if (source.empty()) {
            throw std::runtime_error("Tree-sitter query is empty: " + candidate.string());
        }
        return source;
    }
    throw std::runtime_error("unable to find Tree-sitter query " + std::string(language) + "/" +
                             std::string(query_name) +
                             (searched.empty() ? std::string{} : ": " + searched));
}

std::unique_ptr<TSQuery, decltype(&ts_query_delete)> compile_query(const soda_ts_parser& parser,
                                                                   const char* source) {
    if (source == nullptr) {
        throw std::invalid_argument("Tree-sitter query source is null");
    }
    uint32_t error_offset = 0;
    TSQueryError error_type = TSQueryErrorNone;
    std::unique_ptr<TSQuery, decltype(&ts_query_delete)> query{
        ts_query_new(parser.language, source,
                     static_cast<std::uint32_t>(std::char_traits<char>::length(source)),
                     &error_offset, &error_type),
        ts_query_delete};
    if (!query) {
        throw std::invalid_argument("invalid Tree-sitter query at byte " +
                                    std::to_string(error_offset) + " (error " +
                                    std::to_string(static_cast<int>(error_type)) + ")");
    }
    return query;
}

TSNode root_node(soda_ts_parser& parser);
std::uint32_t node_depth(TSNode node);

soda_ts_query_result* execute_query(soda_ts_parser& parser, const TSQuery* query,
                                    std::uint32_t start, std::uint32_t end) {
    if (query == nullptr) {
        throw std::invalid_argument("Tree-sitter query handle is null");
    }
    if (start > end || end > parser.text.size_bytes()) {
        throw std::out_of_range("Tree-sitter query range is invalid");
    }
    std::unique_ptr<TSQueryCursor, decltype(&ts_query_cursor_delete)> cursor{
        ts_query_cursor_new(), ts_query_cursor_delete};
    if (!cursor) {
        throw std::runtime_error("Tree-sitter query cursor allocation failed");
    }
    ts_query_cursor_set_byte_range(cursor.get(), start, end);
    ts_query_cursor_exec(cursor.get(), query, root_node(parser));
    auto result = std::make_unique<soda_ts_query_result>();
    TSQueryMatch match{};
    uint32_t capture_index = 0;
    while (ts_query_cursor_next_capture(cursor.get(), &match, &capture_index)) {
        const TSQueryCapture capture = match.captures[capture_index];
        uint32_t name_length = 0;
        const char* name = ts_query_capture_name_for_id(query, capture.index, &name_length);
        result->captures.push_back(soda_ts_capture{
            .name = std::string(name, name_length),
            .node_kind = ts_node_type(capture.node),
            .start = ts_node_start_byte(capture.node),
            .end = ts_node_end_byte(capture.node),
            .depth = node_depth(capture.node),
        });
    }
    return result.release();
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

int soda_ts_language_available(const char* language, const char* library, const char* symbol) {
    return guard(-1, [&] {
        if (language == nullptr) {
            throw std::invalid_argument("Tree-sitter language is null");
        }
        LoadedLanguage loaded =
            load_language(language, library == nullptr ? std::string_view{} : library,
                          symbol == nullptr ? std::string_view{} : symbol);
        TSParser* parser = ts_parser_new();
        if (parser == nullptr) {
            close_library(loaded.library);
            throw std::runtime_error("Tree-sitter parser allocation failed");
        }
        const bool compatible = ts_parser_set_language(parser, loaded.language);
        const std::uint32_t language_abi = ts_language_abi_version(loaded.language);
        ts_parser_delete(parser);
        close_library(loaded.library);
        if (!compatible) {
            throw std::runtime_error("Tree-sitter grammar ABI " + std::to_string(language_abi) +
                                     " is outside the supported range " +
                                     std::to_string(TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION) +
                                     "-" + std::to_string(TREE_SITTER_LANGUAGE_VERSION));
        }
        return 1;
    });
}

soda_ts_parser* soda_ts_parser_create(const char* language, const char* library,
                                      const char* symbol) {
    return guard<soda_ts_parser*>(nullptr, [&] {
        if (language == nullptr) {
            throw std::invalid_argument("Tree-sitter language is null");
        }
        auto value = std::make_unique<soda_ts_parser>();
        LoadedLanguage loaded =
            load_language(language, library == nullptr ? std::string_view{} : library,
                          symbol == nullptr ? std::string_view{} : symbol);
        value->language = loaded.language;
        value->language_library = loaded.library;
        value->parser = ts_parser_new();
        if (value->parser == nullptr || !ts_parser_set_language(value->parser, value->language)) {
            ts_parser_delete(value->parser);
            close_library(value->language_library);
            value->language_library = nullptr;
            throw std::runtime_error("Tree-sitter grammar ABI is incompatible");
        }
        return value.release();
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
    close_library(parser->language_library);
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

const char* soda_ts_query_source(const char* language, const char* query_name) {
    return guard<const char*>(nullptr, [&] {
        if (language == nullptr || query_name == nullptr) {
            throw std::invalid_argument("Tree-sitter query resource name is null");
        }
        last_query_source = read_query_source(language, query_name);
        return last_query_source.c_str();
    });
}

soda_ts_query* soda_ts_query_compile(soda_ts_parser* parser, const char* source) {
    return guard<soda_ts_query*>(nullptr, [&] {
        auto& parser_value = parser_handle(parser);
        auto query = compile_query(parser_value, source);
        auto value = std::make_unique<soda_ts_query>();
        value->query = query.release();
        value->language = parser_value.language;
        return value.release();
    });
}

void soda_ts_query_destroy(soda_ts_query* query) {
    if (query == nullptr) {
        return;
    }
    ts_query_delete(query->query);
    delete query;
}

soda_ts_query_result* soda_ts_query_execute(soda_ts_parser* parser, const soda_ts_query* query,
                                            uint32_t start, uint32_t end) {
    return guard<soda_ts_query_result*>(nullptr, [&] {
        auto& parser_value = parser_handle(parser);
        const auto& query_value = require_handle(query, "Tree-sitter query");
        if (query_value.owner != std::this_thread::get_id()) {
            throw std::logic_error("Tree-sitter query used from a non-owning thread");
        }
        if (query_value.language != parser_value.language) {
            throw std::invalid_argument("Tree-sitter query language differs from parser");
        }
        return execute_query(parser_value, query_value.query, start, end);
    });
}

soda_ts_query_result* soda_ts_parser_query(soda_ts_parser* parser, const char* source,
                                           uint32_t start, uint32_t end) {
    return guard<soda_ts_query_result*>(nullptr, [&] {
        auto& value = parser_handle(parser);
        auto query = compile_query(value, source);
        return execute_query(value, query.get(), start, end);
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
