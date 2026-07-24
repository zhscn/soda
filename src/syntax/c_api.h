#pragma once

#include "document/c_api.h"

#include <stdint.h>

#if defined(_WIN32)
#if defined(SODA_CPP_ANALYSIS_BUILD)
#define SODA_CPP_ANALYSIS_API __declspec(dllexport)
#else
#define SODA_CPP_ANALYSIS_API __declspec(dllimport)
#endif
#else
#define SODA_CPP_ANALYSIS_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct soda_cpp_analyzer soda_cpp_analyzer;

#define SODA_CPP_ANALYSIS_ABI_VERSION 1U
#define SODA_SYNTAX_NODE_NONE UINT32_MAX
#define SODA_CPP_ANALYSIS_REVISION_NONE UINT64_MAX

#define SODA_SYNTAX_TRANSLATION_UNIT 0
#define SODA_SYNTAX_PREPROCESSOR_DIRECTIVE 1
#define SODA_SYNTAX_NAMESPACE_DECL 2
#define SODA_SYNTAX_NAMESPACE_BODY 3
#define SODA_SYNTAX_CLASS_DECL 4
#define SODA_SYNTAX_CLASS_BODY 5
#define SODA_SYNTAX_ACCESS_SPECIFIER_LABEL 6
#define SODA_SYNTAX_OPAQUE_DECLARATION 7
#define SODA_SYNTAX_FUNCTION_DEFINITION 8
#define SODA_SYNTAX_CTOR_INITIALIZER_LIST 9
#define SODA_SYNTAX_CTOR_INITIALIZER 10
#define SODA_SYNTAX_PAREN_GROUP 11
#define SODA_SYNTAX_BRACKET_GROUP 12
#define SODA_SYNTAX_BRACE_GROUP 13
#define SODA_SYNTAX_TEMPLATE_ARGUMENT_LIST 14
#define SODA_SYNTAX_COMPOUND_STATEMENT 15
#define SODA_SYNTAX_IF_STATEMENT 16
#define SODA_SYNTAX_ELSE_CLAUSE 17
#define SODA_SYNTAX_FOR_STATEMENT 18
#define SODA_SYNTAX_WHILE_STATEMENT 19
#define SODA_SYNTAX_DO_STATEMENT 20
#define SODA_SYNTAX_SWITCH_STATEMENT 21
#define SODA_SYNTAX_CASE_SECTION 22
#define SODA_SYNTAX_CASE_LABEL 23
#define SODA_SYNTAX_PP_REOPENED_SCOPE 24
#define SODA_SYNTAX_MISSING_TOKEN 25
#define SODA_SYNTAX_ERROR 26

// An analyzer is mutable, belongs to its creating thread, and retains the
// latest analyzed snapshot. Node ids are valid only until the next operation
// that installs or advances analysis on that analyzer. This includes analyze,
// apply, and higher-level ABI operations that accept a mutable analyzer. Node
// ids must originate from root, node_at, node_parent, or node_child.
SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analysis_abi_version(void);
SODA_CPP_ANALYSIS_API const char* soda_cpp_analysis_last_error(void);
SODA_CPP_ANALYSIS_API const char* soda_syntax_kind_name(int kind);

SODA_CPP_ANALYSIS_API soda_cpp_analyzer* soda_cpp_analyzer_create(void);
SODA_CPP_ANALYSIS_API void soda_cpp_analyzer_destroy(soda_cpp_analyzer* analyzer);

// analyze installs the snapshot, reusing a matching cache. apply advances an
// existing matching cache incrementally and otherwise installs a full analysis
// of `after`.
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_analyze(soda_cpp_analyzer* analyzer,
                                                    const soda_snapshot* snapshot);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_apply(soda_cpp_analyzer* analyzer,
                                                  const soda_change* change,
                                                  const soda_snapshot* after);
SODA_CPP_ANALYSIS_API uint64_t soda_cpp_analyzer_revision(const soda_cpp_analyzer* analyzer);
SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analyzer_document_id(const soda_cpp_analyzer* analyzer);

SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analyzer_node_count(const soda_cpp_analyzer* analyzer);
SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analyzer_root(soda_cpp_analyzer* analyzer);
SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analyzer_node_at(soda_cpp_analyzer* analyzer,
                                                         uint32_t offset);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_node_kind(soda_cpp_analyzer* analyzer, uint32_t node);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_node_range(soda_cpp_analyzer* analyzer, uint32_t node,
                                                       uint32_t* start, uint32_t* end);
// Root has no parent and returns SODA_SYNTAX_NODE_NONE with an empty error.
SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analyzer_node_parent(soda_cpp_analyzer* analyzer,
                                                             uint32_t node);
SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analyzer_node_child_count(soda_cpp_analyzer* analyzer,
                                                                  uint32_t node);
SODA_CPP_ANALYSIS_API uint32_t soda_cpp_analyzer_node_child(soda_cpp_analyzer* analyzer,
                                                            uint32_t node, uint32_t child_index);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_node_incomplete(soda_cpp_analyzer* analyzer,
                                                            uint32_t node);

// Optional structural queries return 1 and write a range when found, 0 when
// no range exists, and -1 on error.
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_sexp_forward(soda_cpp_analyzer* analyzer, uint32_t from,
                                                         uint32_t* start, uint32_t* end);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_sexp_backward(soda_cpp_analyzer* analyzer,
                                                          uint32_t from, uint32_t* start,
                                                          uint32_t* end);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_enclosing_list(soda_cpp_analyzer* analyzer,
                                                           uint32_t offset, uint32_t* start,
                                                           uint32_t* end);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_matching_bracket_range(soda_cpp_analyzer* analyzer,
                                                                   uint32_t offset, uint32_t* start,
                                                                   uint32_t* end);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_expand_selection(soda_cpp_analyzer* analyzer,
                                                             uint32_t selection_start,
                                                             uint32_t selection_end,
                                                             uint32_t* start, uint32_t* end);
SODA_CPP_ANALYSIS_API int soda_cpp_analyzer_soft_kill_end(soda_cpp_analyzer* analyzer,
                                                          uint32_t from, uint32_t* start,
                                                          uint32_t* end);

#ifdef __cplusplus
}
#endif
