#pragma once

#include "document/c_api.h"
#include "syntax/c_api.h"

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(SODA_INDENTATION_BUILD)
#define SODA_INDENTATION_API __declspec(dllexport)
#else
#define SODA_INDENTATION_API __declspec(dllimport)
#endif
#else
#define SODA_INDENTATION_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct soda_cpp_indent_style soda_cpp_indent_style;
typedef struct soda_indent_result soda_indent_result;

#define SODA_INDENTATION_ABI_VERSION 1U

#define SODA_INDENT_WIDTH 0
#define SODA_CONTINUATION_INDENT 1
#define SODA_TAB_WIDTH 2
#define SODA_USE_TABS 3
#define SODA_ALIGN_OPEN_BRACKET 4
#define SODA_BRACE_INIT_CONTINUATION 5
#define SODA_INDENT_WRAPPED_FUNCTION_NAMES 6
#define SODA_ALIGN_OPERANDS 7
#define SODA_BREAK_BEFORE_TERNARY 8
#define SODA_NAMESPACE_INDENTATION 9
#define SODA_INDENT_TYPE_BODY 10
#define SODA_INDENT_CASE_LABEL 11
#define SODA_INDENT_CASE_BODY 12
#define SODA_ACCESS_SPECIFIER_OFFSET 13
#define SODA_PP_DIRECTIVE_INDENT 14
#define SODA_PP_INDENT_WIDTH 15
#define SODA_CONSTRUCTOR_INITIALIZERS 16

#define SODA_NAMESPACE_INDENT_NONE 0
#define SODA_NAMESPACE_INDENT_INNER 1
#define SODA_NAMESPACE_INDENT_ALL 2

#define SODA_PP_INDENT_NONE 0
#define SODA_PP_INDENT_AFTER_HASH 1
#define SODA_PP_INDENT_BEFORE_HASH 2

#define SODA_CTOR_NORMAL_INDENT 0
#define SODA_CTOR_CONTINUATION_INDENT 1
#define SODA_CTOR_ALIGN_FIRST_INITIALIZER 2
#define SODA_CTOR_ALIGN_AFTER_COLON 3
#define SODA_CTOR_ALIGN_WITH_COLON 4

SODA_INDENTATION_API uint32_t soda_indentation_abi_version(void);
SODA_INDENTATION_API const char* soda_indentation_last_error(void);

SODA_INDENTATION_API soda_cpp_indent_style* soda_cpp_indent_style_create(void);
SODA_INDENTATION_API soda_cpp_indent_style*
soda_cpp_indent_style_clone(const soda_cpp_indent_style* style);
SODA_INDENTATION_API void soda_cpp_indent_style_destroy(soda_cpp_indent_style* style);
SODA_INDENTATION_API int soda_cpp_indent_style_get(const soda_cpp_indent_style* style, int property,
                                                   int* value);
SODA_INDENTATION_API int soda_cpp_indent_style_set(soda_cpp_indent_style* style, int property,
                                                   int value);

SODA_INDENTATION_API soda_indent_result*
soda_cpp_compute_line_indent(const soda_snapshot* snapshot, soda_cpp_analyzer* analyzer,
                             uint32_t line, const soda_cpp_indent_style* style);
SODA_INDENTATION_API soda_indent_result* soda_cpp_press_enter(soda_document* document,
                                                              soda_cpp_analyzer* analyzer,
                                                              uint32_t caret,
                                                              const soda_cpp_indent_style* style);
SODA_INDENTATION_API soda_indent_result* soda_cpp_type_char(soda_document* document,
                                                            soda_cpp_analyzer* analyzer,
                                                            uint32_t caret, uint8_t character,
                                                            const soda_cpp_indent_style* style);

SODA_INDENTATION_API void soda_indent_result_destroy(soda_indent_result* result);
SODA_INDENTATION_API int soda_indent_result_target_column(const soda_indent_result* result);
SODA_INDENTATION_API int soda_indent_result_role(const soda_indent_result* result);
SODA_INDENTATION_API int soda_indent_result_preserve(const soda_indent_result* result);
SODA_INDENTATION_API uint32_t soda_indent_result_anchor(const soda_indent_result* result);
SODA_INDENTATION_API uint32_t soda_indent_result_caret(const soda_indent_result* result);
SODA_INDENTATION_API int soda_indent_result_reindented(const soda_indent_result* result);
SODA_INDENTATION_API const char* soda_indent_result_handler(const soda_indent_result* result);
SODA_INDENTATION_API uint32_t soda_indent_result_indentation_size(const soda_indent_result* result);
SODA_INDENTATION_API int soda_indent_result_copy_indentation(const soda_indent_result* result,
                                                             uint8_t* destination, size_t capacity);
SODA_INDENTATION_API uint32_t soda_indent_result_trace_count(const soda_indent_result* result);
SODA_INDENTATION_API const char* soda_indent_result_trace(const soda_indent_result* result,
                                                          uint32_t index);
// Transfers the command's change to the caller. Query-only results have no
// change, and a command change can be taken once.
SODA_INDENTATION_API soda_change* soda_indent_result_take_change(soda_indent_result* result);

#ifdef __cplusplus
}
#endif
