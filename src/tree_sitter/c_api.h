#pragma once

#include "document/c_api.h"

#include <stdint.h>

#if defined(_WIN32)
#if defined(SODA_TREE_SITTER_BUILD)
#define SODA_TREE_SITTER_API __declspec(dllexport)
#else
#define SODA_TREE_SITTER_API __declspec(dllimport)
#endif
#else
#define SODA_TREE_SITTER_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct soda_ts_parser soda_ts_parser;
typedef struct soda_ts_query_result soda_ts_query_result;

#define SODA_TREE_SITTER_ABI_VERSION 1U
#define SODA_TREE_SITTER_REVISION_NONE UINT64_MAX

SODA_TREE_SITTER_API uint32_t soda_tree_sitter_abi_version(void);
SODA_TREE_SITTER_API const char* soda_tree_sitter_last_error(void);

// Language grammars are loaded from shared modules.
SODA_TREE_SITTER_API int soda_ts_language_available(const char* language, const char* library,
                                                    const char* symbol);
SODA_TREE_SITTER_API soda_ts_parser* soda_ts_parser_create(const char* language,
                                                           const char* library, const char* symbol);
SODA_TREE_SITTER_API void soda_ts_parser_destroy(soda_ts_parser* parser);
SODA_TREE_SITTER_API int soda_ts_parser_parse(soda_ts_parser* parser,
                                              const soda_snapshot* snapshot);
SODA_TREE_SITTER_API int soda_ts_parser_apply(soda_ts_parser* parser, const soda_change* change,
                                              const soda_snapshot* snapshot);
SODA_TREE_SITTER_API uint32_t soda_ts_parser_document_id(const soda_ts_parser* parser);
SODA_TREE_SITTER_API uint64_t soda_ts_parser_revision(const soda_ts_parser* parser);
SODA_TREE_SITTER_API const char* soda_ts_parser_root_kind(soda_ts_parser* parser);
SODA_TREE_SITTER_API int soda_ts_parser_root_range(soda_ts_parser* parser, uint32_t* start,
                                                   uint32_t* end);
SODA_TREE_SITTER_API int soda_ts_parser_root_has_error(soda_ts_parser* parser);

SODA_TREE_SITTER_API soda_ts_query_result*
soda_ts_parser_query(soda_ts_parser* parser, const char* source, uint32_t start, uint32_t end);
SODA_TREE_SITTER_API void soda_ts_query_result_destroy(soda_ts_query_result* result);
SODA_TREE_SITTER_API uint32_t soda_ts_query_result_count(const soda_ts_query_result* result);
SODA_TREE_SITTER_API const char* soda_ts_query_result_name(const soda_ts_query_result* result,
                                                           uint32_t index);
SODA_TREE_SITTER_API const char* soda_ts_query_result_node_kind(const soda_ts_query_result* result,
                                                                uint32_t index);
SODA_TREE_SITTER_API int soda_ts_query_result_range(const soda_ts_query_result* result,
                                                    uint32_t index, uint32_t* start, uint32_t* end);
SODA_TREE_SITTER_API uint32_t soda_ts_query_result_depth(const soda_ts_query_result* result,
                                                         uint32_t index);

#ifdef __cplusplus
}
#endif
