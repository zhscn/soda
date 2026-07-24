#pragma once

#include <cstdint>

namespace soda {

// How a zero-length anchor behaves when text is inserted exactly at it.
enum class AnchorAffinity : std::uint8_t {
    BeforeInsertion, // anchor stays before the inserted text
    AfterInsertion,  // anchor moves after the inserted text
};

using AnchorId = std::uint32_t;

} // namespace soda
