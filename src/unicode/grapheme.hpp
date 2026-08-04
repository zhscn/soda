#pragma once

#include <cstddef>
#include <optional>
#include <utility>

#include <utf8proc.h>

namespace soda::unicode {

struct DecodedCodepoint {
    utf8proc_int32_t value;
    std::size_t next_offset;
};

// Decode supplies one code point at an absolute byte offset.  Keeping the
// traversal independent from byte storage lets contiguous strings and the
// persistent Text rope share exactly the same UAX #29 boundary algorithm.
template <typename Decode>
std::size_t next_grapheme_offset(std::size_t size, std::size_t start, Decode&& decode) {
    if (start >= size) {
        return size;
    }

    const std::optional<DecodedCodepoint> first = decode(start);
    if (!first.has_value()) {
        return start + 1;
    }

    utf8proc_int32_t previous = first->value;
    std::size_t offset = first->next_offset;
    utf8proc_int32_t state = 0;
    while (offset < size) {
        const std::optional<DecodedCodepoint> current = decode(offset);
        if (!current.has_value()) {
            return offset + 1;
        }
        if (utf8proc_grapheme_break_stateful(previous, current->value, &state)) {
            break;
        }
        previous = current->value;
        offset = current->next_offset;
    }
    return offset;
}

} // namespace soda::unicode
