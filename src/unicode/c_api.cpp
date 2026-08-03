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

size_t soda_unicode_next_grapheme_offset(const uint8_t* bytes, size_t size, size_t start) {
    if (bytes == nullptr || start >= size) {
        return size;
    }
    utf8proc_int32_t previous = 0;
    auto consumed = utf8proc_iterate(bytes + start, static_cast<utf8proc_ssize_t>(size - start),
                                     &previous);
    if (consumed <= 0) {
        return start + 1;
    }
    size_t offset = start + static_cast<size_t>(consumed);
    utf8proc_int32_t state = 0;
    while (offset < size) {
        utf8proc_int32_t current = 0;
        consumed = utf8proc_iterate(bytes + offset, static_cast<utf8proc_ssize_t>(size - offset),
                                    &current);
        if (consumed <= 0) {
            return offset + 1;
        }
        if (utf8proc_grapheme_break_stateful(previous, current, &state)) {
            break;
        }
        previous = current;
        offset += static_cast<size_t>(consumed);
    }
    return offset;
}
