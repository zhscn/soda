#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int soda_unicode_grapheme_width(const uint8_t* bytes, size_t size);
size_t soda_unicode_next_grapheme_offset(const uint8_t* bytes, size_t size, size_t start);

#ifdef __cplusplus
}
#endif
