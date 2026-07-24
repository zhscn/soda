#include "indentation/c_api.h"

#include "commands/editor_commands.hpp"
#include "document/c_api_internal.hpp"
#include "formatting/cpp_indent_style.hpp"
#include "formatting/format_role.hpp"
#include "indentation/indentation_service.hpp"
#include "syntax/c_api_internal.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

static_assert(static_cast<int>(soda::FormatRole::File) == 0);
static_assert(static_cast<int>(soda::FormatRole::Opaque) == 22);

struct soda_cpp_indent_style {
    soda::CppIndentStyle value;
};

struct soda_indent_result {
    soda::IndentDecision decision;
    std::string handler;
    std::optional<soda::TextOffset> caret;
    bool reindented = false;
    std::optional<soda::DocumentChange> change;
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
        set_error("unknown native indentation failure");
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

int boolean_value(int value) {
    if (value != 0 && value != 1) {
        throw std::invalid_argument("boolean style property must be 0 or 1");
    }
    return value;
}

int& integer_property(soda::CppIndentStyle& style, int property) {
    switch (property) {
    case SODA_INDENT_WIDTH:
        return style.indent_width;
    case SODA_CONTINUATION_INDENT:
        return style.continuation_indent;
    case SODA_TAB_WIDTH:
        return style.tab_width;
    case SODA_ACCESS_SPECIFIER_OFFSET:
        return style.access_specifier_offset;
    case SODA_PP_INDENT_WIDTH:
        return style.pp_indent_width;
    default:
        throw std::invalid_argument("style property is not an integer");
    }
}

void set_style_property(soda::CppIndentStyle& style, int property, int value) {
    switch (property) {
    case SODA_INDENT_WIDTH:
    case SODA_CONTINUATION_INDENT:
        if (value < 0) {
            throw std::invalid_argument("indent width must be non-negative");
        }
        integer_property(style, property) = value;
        return;
    case SODA_TAB_WIDTH:
        if (value <= 0) {
            throw std::invalid_argument("tab width must be positive");
        }
        style.tab_width = value;
        return;
    case SODA_ACCESS_SPECIFIER_OFFSET:
        style.access_specifier_offset = value;
        return;
    case SODA_PP_INDENT_WIDTH:
        if (value < -1) {
            throw std::invalid_argument("preprocessor indent width must be at least -1");
        }
        style.pp_indent_width = value;
        return;
    case SODA_USE_TABS:
        style.use_tabs = boolean_value(value) != 0;
        return;
    case SODA_ALIGN_OPEN_BRACKET:
        style.align_open_bracket = boolean_value(value) != 0;
        return;
    case SODA_BRACE_INIT_CONTINUATION:
        style.brace_init_continuation = boolean_value(value) != 0;
        return;
    case SODA_INDENT_WRAPPED_FUNCTION_NAMES:
        style.indent_wrapped_function_names = boolean_value(value) != 0;
        return;
    case SODA_ALIGN_OPERANDS:
        style.align_operands = boolean_value(value) != 0;
        return;
    case SODA_BREAK_BEFORE_TERNARY:
        style.break_before_ternary = boolean_value(value) != 0;
        return;
    case SODA_INDENT_TYPE_BODY:
        style.indent_type_body = boolean_value(value) != 0;
        return;
    case SODA_INDENT_CASE_LABEL:
        style.indent_case_label = boolean_value(value) != 0;
        return;
    case SODA_INDENT_CASE_BODY:
        style.indent_case_body = boolean_value(value) != 0;
        return;
    case SODA_NAMESPACE_INDENTATION:
        if (value < SODA_NAMESPACE_INDENT_NONE || value > SODA_NAMESPACE_INDENT_ALL) {
            throw std::invalid_argument("namespace indentation value is out of range");
        }
        style.namespace_indentation =
            static_cast<soda::CppIndentStyle::NamespaceIndentation>(value);
        return;
    case SODA_PP_DIRECTIVE_INDENT:
        if (value < SODA_PP_INDENT_NONE || value > SODA_PP_INDENT_BEFORE_HASH) {
            throw std::invalid_argument("preprocessor indentation value is out of range");
        }
        style.pp_directive_indent = static_cast<soda::CppIndentStyle::PPDirectiveIndent>(value);
        return;
    case SODA_CONSTRUCTOR_INITIALIZERS:
        if (value < SODA_CTOR_NORMAL_INDENT || value > SODA_CTOR_ALIGN_WITH_COLON) {
            throw std::invalid_argument("constructor initializer style is out of range");
        }
        style.constructor_initializers =
            static_cast<soda::CppIndentStyle::ConstructorInitializerStyle>(value);
        return;
    default:
        throw std::out_of_range("indent style property is out of range");
    }
}

int get_style_property(const soda::CppIndentStyle& style, int property) {
    switch (property) {
    case SODA_INDENT_WIDTH:
        return style.indent_width;
    case SODA_CONTINUATION_INDENT:
        return style.continuation_indent;
    case SODA_TAB_WIDTH:
        return style.tab_width;
    case SODA_USE_TABS:
        return style.use_tabs ? 1 : 0;
    case SODA_ALIGN_OPEN_BRACKET:
        return style.align_open_bracket ? 1 : 0;
    case SODA_BRACE_INIT_CONTINUATION:
        return style.brace_init_continuation ? 1 : 0;
    case SODA_INDENT_WRAPPED_FUNCTION_NAMES:
        return style.indent_wrapped_function_names ? 1 : 0;
    case SODA_ALIGN_OPERANDS:
        return style.align_operands ? 1 : 0;
    case SODA_BREAK_BEFORE_TERNARY:
        return style.break_before_ternary ? 1 : 0;
    case SODA_NAMESPACE_INDENTATION:
        return static_cast<int>(style.namespace_indentation);
    case SODA_INDENT_TYPE_BODY:
        return style.indent_type_body ? 1 : 0;
    case SODA_INDENT_CASE_LABEL:
        return style.indent_case_label ? 1 : 0;
    case SODA_INDENT_CASE_BODY:
        return style.indent_case_body ? 1 : 0;
    case SODA_ACCESS_SPECIFIER_OFFSET:
        return style.access_specifier_offset;
    case SODA_PP_DIRECTIVE_INDENT:
        return static_cast<int>(style.pp_directive_indent);
    case SODA_PP_INDENT_WIDTH:
        return style.pp_indent_width;
    case SODA_CONSTRUCTOR_INITIALIZERS:
        return static_cast<int>(style.constructor_initializers);
    default:
        throw std::out_of_range("indent style property is out of range");
    }
}

int copy_string(std::string_view value, std::uint8_t* destination, std::size_t capacity) {
    if (capacity < value.size()) {
        throw std::invalid_argument("destination is too small");
    }
    if (!value.empty() && destination == nullptr) {
        throw std::invalid_argument("destination is null");
    }
    std::ranges::copy(value, reinterpret_cast<char*>(destination));
    return 0;
}

} // namespace

extern "C" {

uint32_t soda_indentation_abi_version(void) {
    return SODA_INDENTATION_ABI_VERSION;
}

const char* soda_indentation_last_error(void) {
    return last_error.data();
}

soda_cpp_indent_style* soda_cpp_indent_style_create(void) {
    return guard<soda_cpp_indent_style*>(nullptr, [] { return new soda_cpp_indent_style; });
}

soda_cpp_indent_style* soda_cpp_indent_style_clone(const soda_cpp_indent_style* style) {
    return guard<soda_cpp_indent_style*>(
        nullptr, [&] { return new soda_cpp_indent_style(require_handle(style, "indent style")); });
}

void soda_cpp_indent_style_destroy(soda_cpp_indent_style* style) {
    delete style;
}

int soda_cpp_indent_style_get(const soda_cpp_indent_style* style, int property, int* value) {
    return guard(-1, [&] {
        if (value == nullptr) {
            throw std::invalid_argument("style value output is null");
        }
        *value = get_style_property(require_handle(style, "indent style").value, property);
        return 0;
    });
}

int soda_cpp_indent_style_set(soda_cpp_indent_style* style, int property, int value) {
    return guard(-1, [&] {
        set_style_property(require_handle(style, "indent style").value, property, value);
        return 0;
    });
}

soda_indent_result* soda_cpp_compute_line_indent(const soda_snapshot* snapshot,
                                                 soda_cpp_analyzer* analyzer, uint32_t line,
                                                 const soda_cpp_indent_style* style) {
    return guard<soda_indent_result*>(nullptr, [&] {
        const auto& native_snapshot =
            soda::abi::unwrap_snapshot(require_handle(snapshot, "snapshot"));
        (void)soda::abi::unwrap_analyzer(require_handle(analyzer, "C++ analyzer"));
        const auto& analysis = soda::abi::resync_analyzer(*analyzer, native_snapshot);
        auto output = std::make_unique<soda_indent_result>();
        output->decision = soda::compute_line_indent(native_snapshot, analysis.tree, line,
                                                     require_handle(style, "indent style").value);
        return output.release();
    });
}

soda_indent_result* soda_cpp_press_enter(soda_document* document, soda_cpp_analyzer* analyzer,
                                         uint32_t caret, const soda_cpp_indent_style* style) {
    return guard<soda_indent_result*>(nullptr, [&] {
        auto& native_document = soda::abi::unwrap_document(require_handle(document, "document"));
        auto& native_analyzer =
            soda::abi::unwrap_analyzer(require_handle(analyzer, "C++ analyzer"));
        soda::EnterResult result =
            soda::press_enter(native_document, soda::TextOffset{caret},
                              require_handle(style, "indent style").value, native_analyzer);
        auto output = std::make_unique<soda_indent_result>();
        output->decision = std::move(result.decision);
        output->handler = std::move(result.handler);
        output->caret = result.caret;
        output->change = std::move(result.change);
        (void)soda::abi::resync_analyzer(*analyzer, native_document.snapshot());
        return output.release();
    });
}

soda_indent_result* soda_cpp_type_char(soda_document* document, soda_cpp_analyzer* analyzer,
                                       uint32_t caret, uint8_t character,
                                       const soda_cpp_indent_style* style) {
    return guard<soda_indent_result*>(nullptr, [&] {
        auto& native_document = soda::abi::unwrap_document(require_handle(document, "document"));
        auto& native_analyzer =
            soda::abi::unwrap_analyzer(require_handle(analyzer, "C++ analyzer"));
        soda::TypeCharResult result =
            soda::type_char(native_document, soda::TextOffset{caret}, static_cast<char>(character),
                            require_handle(style, "indent style").value, native_analyzer);
        auto output = std::make_unique<soda_indent_result>();
        output->decision = std::move(result.decision);
        output->handler = "TypeChar";
        output->caret = result.caret;
        output->reindented = result.reindented;
        output->change = std::move(result.change);
        (void)soda::abi::resync_analyzer(*analyzer, native_document.snapshot());
        return output.release();
    });
}

void soda_indent_result_destroy(soda_indent_result* result) {
    delete result;
}

int soda_indent_result_target_column(const soda_indent_result* result) {
    return guard(-1,
                 [&] { return require_handle(result, "indent result").decision.target_column; });
}

int soda_indent_result_role(const soda_indent_result* result) {
    return guard(-1, [&] {
        return static_cast<int>(require_handle(result, "indent result").decision.role);
    });
}

int soda_indent_result_preserve(const soda_indent_result* result) {
    return guard(-1,
                 [&] { return require_handle(result, "indent result").decision.preserve ? 1 : 0; });
}

uint32_t soda_indent_result_anchor(const soda_indent_result* result) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        const auto& anchor = require_handle(result, "indent result").decision.anchor;
        return anchor.has_value() ? anchor->value : SODA_TEXT_NPOS;
    });
}

uint32_t soda_indent_result_caret(const soda_indent_result* result) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        const auto& caret = require_handle(result, "indent result").caret;
        return caret.has_value() ? caret->value : SODA_TEXT_NPOS;
    });
}

int soda_indent_result_reindented(const soda_indent_result* result) {
    return guard(-1, [&] { return require_handle(result, "indent result").reindented ? 1 : 0; });
}

const char* soda_indent_result_handler(const soda_indent_result* result) {
    return guard<const char*>(
        nullptr, [&] { return require_handle(result, "indent result").handler.c_str(); });
}

uint32_t soda_indent_result_indentation_size(const soda_indent_result* result) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        const auto size = require_handle(result, "indent result").decision.indentation_text.size();
        if (size > std::numeric_limits<std::uint32_t>::max()) {
            throw std::overflow_error("indentation text exceeds the ABI range");
        }
        return static_cast<std::uint32_t>(size);
    });
}

int soda_indent_result_copy_indentation(const soda_indent_result* result, uint8_t* destination,
                                        size_t capacity) {
    return guard(-1, [&] {
        return copy_string(require_handle(result, "indent result").decision.indentation_text,
                           destination, capacity);
    });
}

uint32_t soda_indent_result_trace_count(const soda_indent_result* result) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        const auto size = require_handle(result, "indent result").decision.trace.size();
        if (size > std::numeric_limits<std::uint32_t>::max()) {
            throw std::overflow_error("indent trace count exceeds the ABI range");
        }
        return static_cast<std::uint32_t>(size);
    });
}

const char* soda_indent_result_trace(const soda_indent_result* result, uint32_t index) {
    return guard<const char*>(nullptr, [&] {
        const auto& trace = require_handle(result, "indent result").decision.trace;
        if (index >= trace.size()) {
            throw std::out_of_range("indent trace index is out of range");
        }
        return trace[index].c_str();
    });
}

soda_change* soda_indent_result_take_change(soda_indent_result* result) {
    return guard<soda_change*>(nullptr, [&] {
        auto& change = require_handle(result, "indent result").change;
        if (!change.has_value()) {
            throw std::logic_error("indent result has no available document change");
        }
        soda_change* output = soda::abi::wrap_change(std::move(*change));
        change.reset();
        return output;
    });
}

} // extern "C"
