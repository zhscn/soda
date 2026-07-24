#pragma once

#include "document/c_api.h"
#include "document/snapshot.hpp"
#include "document/text.hpp"
#include "document/text_types.hpp"

namespace soda::abi {

// Native-library seam for building additional opaque C ABIs without
// serializing persistent values through their public C accessors.
const Text& unwrap_text(const soda_text& text) noexcept;
const DocumentSnapshot& unwrap_snapshot(const soda_snapshot& snapshot) noexcept;
const DocumentChange& unwrap_change(const soda_change& change) noexcept;

} // namespace soda::abi
