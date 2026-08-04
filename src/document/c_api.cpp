#include "document/c_api.h"

#include "document/c_api_internal.hpp"
#include "document/document.hpp"
#include "document/text.hpp"
#include "unicode/grapheme.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

#include <utf8proc.h>

struct soda_text {
    explicit soda_text(soda::Text requested_value) : value(std::move(requested_value)) {}

    soda::Text value;
};

struct soda_snapshot {
    explicit soda_snapshot(soda::DocumentSnapshot requested_value)
        : value(std::move(requested_value)) {}

    soda::DocumentSnapshot value;
};

struct soda_change {
    soda::DocumentChange value;
};

struct soda_document_state {
    soda_document_state(std::string text, soda::DocumentId id)
        : value(std::move(text), id), owner(std::this_thread::get_id()) {}

    soda::Document value;
    const std::thread::id owner;
};

struct soda_document {
    explicit soda_document(std::shared_ptr<soda_document_state> requested_state)
        : state(std::move(requested_state)) {}

    std::shared_ptr<soda_document_state> state;
};

struct soda_transaction {
    explicit soda_transaction(std::shared_ptr<soda_document_state> requested_state)
        : state(std::move(requested_state)), value(state->value.begin_transaction()) {}

    std::shared_ptr<soda_document_state> state;
    std::optional<soda::EditTransaction> value;
};

namespace {

thread_local std::array<char, 512> last_error{};

void clear_error() noexcept {
    last_error.front() = '\0';
}

void set_error(std::string_view message) noexcept {
    const std::size_t size = std::min(message.size(), last_error.size() - 1);
    std::ranges::copy_n(message.begin(), static_cast<std::ptrdiff_t>(size), last_error.begin());
    last_error[size] = '\0';
}

template <typename Result, typename Operation>
Result guard(Result failure, Operation&& operation) noexcept {
    try {
        clear_error();
        return std::forward<Operation>(operation)();
    } catch (const std::exception& exception) {
        set_error(exception.what());
    } catch (...) {
        set_error("unknown native document failure");
    }
    return failure;
}

std::string_view bytes(const std::uint8_t* data, std::size_t size) {
    constexpr std::size_t maximum_size =
        static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max()) - 1;
    if (size > maximum_size) {
        throw std::length_error("text exceeds the native 32-bit offset space");
    }
    if (size == 0) {
        return {};
    }
    if (data == nullptr) {
        throw std::invalid_argument("text data is null");
    }
    return {reinterpret_cast<const char*>(data), size};
}

template <typename Handle>
const Handle& require_handle(const Handle* handle, std::string_view kind) {
    if (handle == nullptr) {
        throw std::invalid_argument(std::string(kind) + " handle is null");
    }
    return *handle;
}

template <typename Handle> Handle& require_handle(Handle* handle, std::string_view kind) {
    if (handle == nullptr) {
        throw std::invalid_argument(std::string(kind) + " handle is null");
    }
    return *handle;
}

void require_owner(const soda_document_state& state) {
    if (state.owner != std::this_thread::get_id()) {
        throw std::logic_error("document used from a non-owning thread");
    }
}

void require_owner_or_terminate(const soda_document_state& state) noexcept {
    if (state.owner != std::this_thread::get_id()) {
        std::terminate();
    }
}

soda_document_state& document_state(soda_document* document) {
    auto& handle = require_handle(document, "document");
    require_owner(*handle.state);
    return *handle.state;
}

const soda_document_state& document_state(const soda_document* document) {
    const auto& handle = require_handle(document, "document");
    require_owner(*handle.state);
    return *handle.state;
}

soda::AnchorAffinity anchor_affinity(int affinity) {
    switch (affinity) {
    case SODA_ANCHOR_BEFORE_INSERTION:
        return soda::AnchorAffinity::BeforeInsertion;
    case SODA_ANCHOR_AFTER_INSERTION:
        return soda::AnchorAffinity::AfterInsertion;
    default:
        throw std::invalid_argument("invalid anchor affinity");
    }
}

int anchor_affinity(soda::AnchorAffinity affinity) noexcept {
    return affinity == soda::AnchorAffinity::BeforeInsertion ? SODA_ANCHOR_BEFORE_INSERTION
                                                             : SODA_ANCHOR_AFTER_INSERTION;
}

soda::EditTransaction& transaction_value(soda_transaction* transaction) {
    auto& handle = require_handle(transaction, "transaction");
    require_owner(*handle.state);
    if (!handle.value.has_value() || !handle.value->active()) {
        throw std::logic_error("transaction is inactive");
    }
    return *handle.value;
}

const soda::EditTransaction& transaction_value(const soda_transaction* transaction) {
    const auto& handle = require_handle(transaction, "transaction");
    require_owner(*handle.state);
    if (!handle.value.has_value() || !handle.value->active()) {
        throw std::logic_error("transaction is inactive");
    }
    return *handle.value;
}

const soda::TextEdit& change_edit(const soda_change* change, std::uint32_t edit_index) {
    const auto& handle = require_handle(change, "change");
    if (edit_index >= handle.value.edits.size()) {
        throw std::out_of_range("change edit index is out of range");
    }
    return handle.value.edits[edit_index];
}

const soda::TextEdit& transaction_edit(const soda_transaction* transaction,
                                       std::uint32_t edit_index) {
    const auto edits = transaction_value(transaction).pending_edits();
    if (edit_index >= edits.size()) {
        throw std::out_of_range("transaction edit index is out of range");
    }
    return edits[edit_index];
}

int copy_string(std::string_view value, std::uint8_t* destination, std::size_t capacity) {
    if (capacity < value.size()) {
        throw std::invalid_argument("destination is too small");
    }
    if (!value.empty() && destination == nullptr) {
        throw std::invalid_argument("destination is null");
    }
    std::ranges::copy(value, reinterpret_cast<char*>(destination));
    return 0;
}

void write_range(soda::TextRange range, std::uint32_t* start, std::uint32_t* end) {
    if (start == nullptr || end == nullptr) {
        throw std::invalid_argument("range output is null");
    }
    *start = range.start.value;
    *end = range.end.value;
}

} // namespace

namespace soda::abi {

const Text& unwrap_text(const soda_text& text) noexcept {
    return text.value;
}

const DocumentSnapshot& unwrap_snapshot(const soda_snapshot& snapshot) noexcept {
    return snapshot.value;
}

const DocumentChange& unwrap_change(const soda_change& change) noexcept {
    return change.value;
}

Document& unwrap_document(soda_document& document) {
    require_owner(*document.state);
    return document.state->value;
}

soda_change* wrap_change(DocumentChange change) {
    auto output = std::make_unique<soda_change>();
    output->value = std::move(change);
    return output.release();
}

} // namespace soda::abi

extern "C" {

uint32_t soda_document_abi_version(void) {
    return SODA_DOCUMENT_ABI_VERSION;
}

const char* soda_document_last_error(void) {
    return last_error.data();
}

soda_text* soda_text_create(const uint8_t* data, size_t size) {
    return guard<soda_text*>(nullptr, [&] { return new soda_text(soda::Text(bytes(data, size))); });
}

soda_text* soda_text_clone(const soda_text* text) {
    return guard<soda_text*>(nullptr,
                             [&] { return new soda_text(require_handle(text, "text").value); });
}

void soda_text_destroy(soda_text* text) {
    delete text;
}

uint32_t soda_text_size(const soda_text* text) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS,
                                [&] { return require_handle(text, "text").value.size_bytes(); });
}

uint32_t soda_text_line_count(const soda_text* text) {
    return guard<std::uint32_t>(0, [&] { return require_handle(text, "text").value.line_count(); });
}

uint32_t soda_text_utf16_size(const soda_text* text) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS,
                                [&] { return require_handle(text, "text").value.utf16_size(); });
}

int soda_text_copy(const soda_text* text, uint32_t start, uint32_t end, uint8_t* destination,
                   size_t capacity) {
    return guard(-1, [&] {
        const std::string value =
            require_handle(text, "text").value.substring(soda::make_range(start, end));
        return copy_string(value, destination, capacity);
    });
}

int soda_text_byte_at(const soda_text* text, uint32_t offset) {
    return guard(-1, [&] {
        const char value = require_handle(text, "text").value.byte_at(soda::TextOffset{offset});
        return static_cast<int>(static_cast<unsigned char>(value));
    });
}

uint32_t soda_text_next_grapheme_offset(const soda_text* text, uint32_t offset) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        const soda::Text& value = require_handle(text, "text").value;
        const std::uint32_t size = value.size_bytes();
        if (offset >= size) {
            return size;
        }
        return static_cast<std::uint32_t>(soda::unicode::next_grapheme_offset(
            size, offset, [&](std::size_t position) {
                std::array<std::uint8_t, 4> bytes{};
                const std::size_t available = std::min<std::size_t>(bytes.size(), size - position);
                for (std::size_t index = 0; index < available; ++index) {
                    bytes[index] = static_cast<std::uint8_t>(
                        value.byte_at(soda::TextOffset{static_cast<std::uint32_t>(position + index)}));
                }
                utf8proc_int32_t codepoint = 0;
                const auto consumed = utf8proc_iterate(
                    bytes.data(), static_cast<utf8proc_ssize_t>(available), &codepoint);
                if (consumed <= 0) {
                    return std::optional<soda::unicode::DecodedCodepoint>{};
                }
                return std::optional<soda::unicode::DecodedCodepoint>{
                    soda::unicode::DecodedCodepoint{
                        codepoint, position + static_cast<std::size_t>(consumed)}};
            }));
    });
}

uint32_t soda_text_line_start(const soda_text* text, uint32_t line) {
    return guard<std::uint32_t>(
        SODA_TEXT_NPOS, [&] { return require_handle(text, "text").value.line_start(line).value; });
}

uint32_t soda_text_line_content_end(const soda_text* text, uint32_t line) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(text, "text").value.line_content_end(line).value;
    });
}

int soda_text_position(const soda_text* text, uint32_t offset, uint32_t* line,
                       uint32_t* byte_column) {
    return guard(-1, [&] {
        if (line == nullptr || byte_column == nullptr) {
            throw std::invalid_argument("position output is null");
        }
        const soda::LinePosition position =
            require_handle(text, "text").value.position(soda::TextOffset{offset});
        *line = position.line;
        *byte_column = position.byte_column;
        return 0;
    });
}

uint32_t soda_text_offset(const soda_text* text, uint32_t line, uint32_t byte_column) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(text, "text")
            .value.offset(soda::LinePosition{line, byte_column})
            .value;
    });
}

uint32_t soda_text_utf16_offset(const soda_text* text, uint32_t offset) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(text, "text").value.utf16_offset(soda::TextOffset{offset});
    });
}

uint32_t soda_text_offset_at_utf16(const soda_text* text, uint32_t utf16_offset) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(text, "text").value.offset_at_utf16(utf16_offset).value;
    });
}

soda_document* soda_document_create(const uint8_t* data, size_t size, uint32_t document_id) {
    return guard<soda_document*>(nullptr, [&] {
        auto state =
            std::make_shared<soda_document_state>(std::string(bytes(data, size)), document_id);
        return new soda_document(std::move(state));
    });
}

soda_document* soda_document_create_from_text(const soda_text* text, uint32_t document_id) {
    return guard<soda_document*>(nullptr, [&] {
        auto state = std::make_shared<soda_document_state>(
            require_handle(text, "text").value.to_string(), document_id);
        return new soda_document(std::move(state));
    });
}

void soda_document_destroy(soda_document* document) {
    if (document != nullptr) {
        require_owner_or_terminate(*document->state);
    }
    delete document;
}

uint32_t soda_document_id(const soda_document* document) {
    return guard<std::uint32_t>(0, [&] { return document_state(document).value.id(); });
}

uint64_t soda_document_revision(const soda_document* document) {
    return guard<std::uint64_t>(std::numeric_limits<std::uint64_t>::max(),
                                [&] { return document_state(document).value.revision(); });
}

soda_snapshot* soda_document_snapshot(const soda_document* document) {
    return guard<soda_snapshot*>(
        nullptr, [&] { return new soda_snapshot(document_state(document).value.snapshot()); });
}

soda_transaction* soda_document_begin_transaction(soda_document* document) {
    return guard<soda_transaction*>(nullptr, [&] {
        auto& handle = require_handle(document, "document");
        require_owner(*handle.state);
        return new soda_transaction(handle.state);
    });
}

int soda_document_can_undo(const soda_document* document) {
    return guard(-1, [&] { return document_state(document).value.can_undo() ? 1 : 0; });
}

int soda_document_can_redo(const soda_document* document) {
    return guard(-1, [&] { return document_state(document).value.can_redo() ? 1 : 0; });
}

soda_change* soda_document_undo(soda_document* document) {
    return guard<soda_change*>(nullptr, [&]() -> soda_change* {
        auto output = std::make_unique<soda_change>();
        auto change = document_state(document).value.undo();
        if (!change.has_value()) {
            return nullptr;
        }
        output->value = std::move(*change);
        return output.release();
    });
}

soda_change* soda_document_redo(soda_document* document) {
    return guard<soda_change*>(nullptr, [&]() -> soda_change* {
        auto output = std::make_unique<soda_change>();
        auto change = document_state(document).value.redo();
        if (!change.has_value()) {
            return nullptr;
        }
        output->value = std::move(*change);
        return output.release();
    });
}

soda_change* soda_document_undo_to(soda_document* document, uint32_t undo_node) {
    return guard<soda_change*>(nullptr, [&] {
        auto output = std::make_unique<soda_change>();
        output->value = document_state(document).value.undo_to(undo_node);
        return output.release();
    });
}

uint32_t soda_document_undo_position(const soda_document* document) {
    return guard<std::uint32_t>(SODA_UNDO_NODE_NONE,
                                [&] { return document_state(document).value.undo_position(); });
}

uint32_t soda_document_undo_node_count(const soda_document* document) {
    return guard<std::uint32_t>(0,
                                [&] { return document_state(document).value.undo_node_count(); });
}

uint32_t soda_document_undo_parent(const soda_document* document, uint32_t undo_node) {
    return guard<std::uint32_t>(
        SODA_UNDO_NODE_NONE, [&] { return document_state(document).value.undo_parent(undo_node); });
}

uint32_t soda_document_undo_child_count(const soda_document* document, uint32_t undo_node) {
    return guard<std::uint32_t>(0, [&] {
        const auto size = document_state(document).value.undo_children(undo_node).size();
        return static_cast<std::uint32_t>(size);
    });
}

uint32_t soda_document_undo_child(const soda_document* document, uint32_t undo_node,
                                  uint32_t child_index) {
    return guard<std::uint32_t>(SODA_UNDO_NODE_NONE, [&] {
        const auto& children = document_state(document).value.undo_children(undo_node);
        if (child_index >= children.size()) {
            throw std::out_of_range("undo child index is out of range");
        }
        return children[child_index];
    });
}

uint32_t soda_document_create_anchor(soda_document* document, uint32_t offset, int affinity) {
    return guard<std::uint32_t>(0, [&] {
        return document_state(document).value.create_anchor(soda::TextOffset{offset},
                                                            anchor_affinity(affinity));
    });
}

int soda_document_remove_anchor(soda_document* document, uint32_t anchor) {
    return guard(-1, [&] {
        document_state(document).value.remove_anchor(anchor);
        return 0;
    });
}

uint32_t soda_document_anchor_offset(const soda_document* document, uint32_t anchor) {
    return guard<std::uint32_t>(
        SODA_TEXT_NPOS, [&] { return document_state(document).value.anchor_offset(anchor).value; });
}

int soda_document_anchor_affinity(const soda_document* document, uint32_t anchor) {
    return guard(-1, [&] {
        return anchor_affinity(document_state(document).value.anchor_affinity(anchor));
    });
}

int soda_document_set_anchor_affinity(soda_document* document, uint32_t anchor, int affinity) {
    return guard(-1, [&] {
        document_state(document).value.set_anchor_affinity(anchor, anchor_affinity(affinity));
        return 0;
    });
}

int soda_document_set_editable_start(soda_document* document, uint32_t offset) {
    return guard(-1, [&] {
        std::optional<soda::TextOffset> boundary;
        if (offset != SODA_TEXT_NPOS) {
            boundary = soda::TextOffset{offset};
        }
        document_state(document).value.set_editable_start(boundary);
        return 0;
    });
}

uint32_t soda_document_editable_start(const soda_document* document) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        const auto boundary = document_state(document).value.editable_start();
        return boundary.has_value() ? boundary->value : SODA_TEXT_NPOS;
    });
}

void soda_snapshot_destroy(soda_snapshot* snapshot) {
    delete snapshot;
}

uint32_t soda_snapshot_document_id(const soda_snapshot* snapshot) {
    return guard<std::uint32_t>(
        0, [&] { return require_handle(snapshot, "snapshot").value.document_id(); });
}

uint64_t soda_snapshot_revision(const soda_snapshot* snapshot) {
    return guard<std::uint64_t>(std::numeric_limits<std::uint64_t>::max(), [&] {
        return require_handle(snapshot, "snapshot").value.revision();
    });
}

soda_text* soda_snapshot_text(const soda_snapshot* snapshot) {
    return guard<soda_text*>(nullptr, [&] {
        return new soda_text(require_handle(snapshot, "snapshot").value.content());
    });
}

void soda_transaction_destroy(soda_transaction* transaction) {
    if (transaction != nullptr) {
        require_owner_or_terminate(*transaction->state);
    }
    delete transaction;
}

int soda_transaction_replace(soda_transaction* transaction, uint32_t start, uint32_t end,
                             const uint8_t* replacement, size_t replacement_size) {
    return guard(-1, [&] {
        transaction_value(transaction)
            .replace(soda::make_range(start, end), bytes(replacement, replacement_size));
        return 0;
    });
}

int soda_transaction_insert(soda_transaction* transaction, uint32_t offset, const uint8_t* text,
                            size_t size) {
    return soda_transaction_replace(transaction, offset, offset, text, size);
}

int soda_transaction_erase(soda_transaction* transaction, uint32_t start, uint32_t end) {
    return soda_transaction_replace(transaction, start, end, nullptr, 0);
}

uint32_t soda_transaction_anchor_offset(const soda_transaction* transaction, uint32_t anchor) {
    return guard<std::uint32_t>(
        SODA_TEXT_NPOS, [&] { return transaction_value(transaction).anchor_offset(anchor).value; });
}

int soda_transaction_set_anchor_affinity(soda_transaction* transaction, uint32_t anchor,
                                         int affinity) {
    return guard(-1, [&] {
        transaction_value(transaction).set_anchor_affinity(anchor, anchor_affinity(affinity));
        return 0;
    });
}

uint64_t soda_transaction_base_revision(const soda_transaction* transaction) {
    return guard<std::uint64_t>(std::numeric_limits<std::uint64_t>::max(),
                                [&] { return transaction_value(transaction).base_revision(); });
}

uint32_t soda_transaction_pending_edit_count(const soda_transaction* transaction) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return static_cast<std::uint32_t>(transaction_value(transaction).pending_edits().size());
    });
}

int soda_transaction_pending_edit_range(const soda_transaction* transaction, uint32_t edit_index,
                                        uint32_t* start, uint32_t* end) {
    return guard(-1, [&] {
        write_range(transaction_edit(transaction, edit_index).old_range, start, end);
        return 0;
    });
}

uint32_t soda_transaction_pending_edit_text_size(const soda_transaction* transaction,
                                                 uint32_t edit_index) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return static_cast<std::uint32_t>(
            transaction_edit(transaction, edit_index).new_text.size());
    });
}

int soda_transaction_copy_pending_edit_text(const soda_transaction* transaction,
                                            uint32_t edit_index, uint8_t* destination,
                                            size_t capacity) {
    return guard(-1, [&] {
        return copy_string(transaction_edit(transaction, edit_index).new_text, destination,
                           capacity);
    });
}

soda_snapshot* soda_transaction_snapshot(const soda_transaction* transaction) {
    return guard<soda_snapshot*>(nullptr, [&] {
        return new soda_snapshot(transaction_value(transaction).speculative_snapshot());
    });
}

soda_change* soda_transaction_commit(soda_transaction* transaction) {
    return guard<soda_change*>(nullptr, [&] {
        auto output = std::make_unique<soda_change>();
        auto& handle = require_handle(transaction, "transaction");
        soda::CommitResult result = transaction_value(transaction).commit();
        output->value = std::move(result.change);
        handle.value.reset();
        return output.release();
    });
}

int soda_transaction_abort(soda_transaction* transaction) {
    return guard(-1, [&] {
        auto& handle = require_handle(transaction, "transaction");
        transaction_value(transaction).abort();
        handle.value.reset();
        return 0;
    });
}

void soda_change_destroy(soda_change* change) {
    delete change;
}

uint64_t soda_change_old_revision(const soda_change* change) {
    return guard<std::uint64_t>(std::numeric_limits<std::uint64_t>::max(), [&] {
        return require_handle(change, "change").value.old_revision;
    });
}

uint64_t soda_change_new_revision(const soda_change* change) {
    return guard<std::uint64_t>(std::numeric_limits<std::uint64_t>::max(), [&] {
        return require_handle(change, "change").value.new_revision;
    });
}

uint32_t soda_change_edit_count(const soda_change* change) {
    return guard<std::uint32_t>(0, [&] {
        return static_cast<std::uint32_t>(require_handle(change, "change").value.edits.size());
    });
}

int soda_change_edit_range(const soda_change* change, uint32_t edit_index, uint32_t* start,
                           uint32_t* end) {
    return guard(-1, [&] {
        write_range(change_edit(change, edit_index).old_range, start, end);
        return 0;
    });
}

uint32_t soda_change_edit_start(const soda_change* change, uint32_t edit_index) {
    return guard<std::uint32_t>(
        SODA_TEXT_NPOS, [&] { return change_edit(change, edit_index).old_range.start.value; });
}

uint32_t soda_change_edit_end(const soda_change* change, uint32_t edit_index) {
    return guard<std::uint32_t>(
        SODA_TEXT_NPOS, [&] { return change_edit(change, edit_index).old_range.end.value; });
}

uint32_t soda_change_edit_text_size(const soda_change* change, uint32_t edit_index) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return static_cast<std::uint32_t>(change_edit(change, edit_index).new_text.size());
    });
}

int soda_change_copy_edit_text(const soda_change* change, uint32_t edit_index, uint8_t* destination,
                               size_t capacity) {
    return guard(-1, [&] {
        return copy_string(change_edit(change, edit_index).new_text, destination, capacity);
    });
}

int soda_change_affected_old_range(const soda_change* change, uint32_t* start, uint32_t* end) {
    return guard(-1, [&] {
        write_range(require_handle(change, "change").value.affected_old_range, start, end);
        return 0;
    });
}

int soda_change_affected_new_range(const soda_change* change, uint32_t* start, uint32_t* end) {
    return guard(-1, [&] {
        write_range(require_handle(change, "change").value.affected_new_range, start, end);
        return 0;
    });
}

uint32_t soda_change_affected_old_start(const soda_change* change) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(change, "change").value.affected_old_range.start.value;
    });
}

uint32_t soda_change_affected_old_end(const soda_change* change) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(change, "change").value.affected_old_range.end.value;
    });
}

uint32_t soda_change_affected_new_start(const soda_change* change) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(change, "change").value.affected_new_range.start.value;
    });
}

uint32_t soda_change_affected_new_end(const soda_change* change) {
    return guard<std::uint32_t>(SODA_TEXT_NPOS, [&] {
        return require_handle(change, "change").value.affected_new_range.end.value;
    });
}

} // extern "C"
