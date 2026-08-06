#pragma once

#include "document/c_api.h"

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(SODA_REGEX_BUILD)
#define SODA_REGEX_API __declspec(dllexport)
#else
#define SODA_REGEX_API __declspec(dllimport)
#endif
#else
#define SODA_REGEX_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct soda_regex soda_regex;
typedef struct soda_regex_matches soda_regex_matches;

#define SODA_REGEX_ABI_VERSION 1U

#define SODA_REGEX_FORWARD 1
#define SODA_REGEX_BACKWARD -1

SODA_REGEX_API uint32_t soda_regex_abi_version(void);
SODA_REGEX_API const char* soda_regex_last_error(void);

// Compiles a POSIX extended regular expression.  The matcher operates on
// UTF-8 byte offsets, the same coordinate system exposed by soda_text.
SODA_REGEX_API soda_regex* soda_regex_compile(const uint8_t* pattern, size_t size,
                                              int case_sensitive);
SODA_REGEX_API void soda_regex_destroy(soda_regex* regex);

// Searches [start, end) and writes the selected non-overlapping match.  A
// return value of 1 means a match was found, 0 means no match, and -1 means
// an invalid request or native failure (inspect soda_regex_last_error()).
SODA_REGEX_API int soda_regex_find(const soda_regex* regex, const soda_text* text,
                                   uint32_t start, uint32_t end, int direction,
                                   uint32_t* match_start, uint32_t* match_end);

// Captures all non-overlapping matches in [start, end).  Empty matches are
// advanced by one UTF-8 character so collection always terminates.
SODA_REGEX_API soda_regex_matches* soda_regex_collect(const soda_regex* regex,
                                                      const soda_text* text,
                                                      uint32_t start, uint32_t end);
SODA_REGEX_API void soda_regex_matches_destroy(soda_regex_matches* matches);
SODA_REGEX_API uint32_t soda_regex_matches_count(const soda_regex_matches* matches);
SODA_REGEX_API int soda_regex_matches_range(const soda_regex_matches* matches,
                                            uint32_t index, uint32_t* match_start,
                                            uint32_t* match_end);

#ifdef __cplusplus
}
#endif
