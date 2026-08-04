#include "unicode/c_api.h"
#include "unicode/grapheme.hpp"

#include <utf8proc.h>

#include <optional>

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

size_t soda_unicode_next_grapheme_offset(const uint8_t* bytes, size_t size, size_t start) {
    if (bytes == nullptr || start >= size) {
        return size;
    }
    return soda::unicode::next_grapheme_offset(size, start, [&](size_t offset) {
        utf8proc_int32_t value = 0;
        const auto consumed = utf8proc_iterate(
            bytes + offset, static_cast<utf8proc_ssize_t>(size - offset), &value);
        if (consumed <= 0) {
            return std::optional<soda::unicode::DecodedCodepoint>{};
        }
        return std::optional<soda::unicode::DecodedCodepoint>{
            soda::unicode::DecodedCodepoint{value, offset + static_cast<size_t>(consumed)}};
    });
}
