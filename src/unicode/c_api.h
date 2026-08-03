#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int soda_unicode_grapheme_width(const uint8_t* bytes, size_t size);

#ifdef __cplusplus
}
#endif
