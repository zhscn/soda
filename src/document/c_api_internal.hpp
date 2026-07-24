#pragma once

#include "document/c_api.h"
#include "document/document.hpp"
#include "document/snapshot.hpp"
#include "document/text.hpp"
#include "document/text_types.hpp"

namespace soda::abi {

// Native-library seam for building additional opaque C ABIs without
// serializing persistent values through their public C accessors.
SODA_DOCUMENT_API const Text& unwrap_text(const soda_text& text) noexcept;
SODA_DOCUMENT_API const DocumentSnapshot& unwrap_snapshot(const soda_snapshot& snapshot) noexcept;
SODA_DOCUMENT_API const DocumentChange& unwrap_change(const soda_change& change) noexcept;
SODA_DOCUMENT_API Document& unwrap_document(soda_document& document);
SODA_DOCUMENT_API soda_change* wrap_change(DocumentChange change);

} // namespace soda::abi
