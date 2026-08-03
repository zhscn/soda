#include "unicode/c_api.h"

#include <utf8proc.h>

int soda_unicode_grapheme_width(const uint8_t* bytes, size_t size) {
    if (bytes == nullptr || size == 0) {
        return 0;
    }
    utf8proc_int32_t codepoint = 0;
    const auto consumed = utf8proc_iterate(bytes, static_cast<utf8proc_ssize_t>(size), &codepoint);
    if (consumed < 0) {
        return 1;
    }
    const auto width = utf8proc_charwidth(codepoint);
    return width < 0 ? 1 : width;
}
