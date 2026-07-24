#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "document/c_api.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>

namespace {

struct TextDeleter {
    void operator()(soda_text* value) const { soda_text_destroy(value); }
};

struct DocumentDeleter {
    void operator()(soda_document* value) const { soda_document_destroy(value); }
};

struct SnapshotDeleter {
    void operator()(soda_snapshot* value) const { soda_snapshot_destroy(value); }
};

struct TransactionDeleter {
    void operator()(soda_transaction* value) const { soda_transaction_destroy(value); }
};

struct ChangeDeleter {
    void operator()(soda_change* value) const { soda_change_destroy(value); }
};

using TextHandle = std::unique_ptr<soda_text, TextDeleter>;
using DocumentHandle = std::unique_ptr<soda_document, DocumentDeleter>;
using SnapshotHandle = std::unique_ptr<soda_snapshot, SnapshotDeleter>;
using TransactionHandle = std::unique_ptr<soda_transaction, TransactionDeleter>;
using ChangeHandle = std::unique_ptr<soda_change, ChangeDeleter>;

TextHandle make_text(std::string_view value) {
    return TextHandle(
        soda_text_create(reinterpret_cast<const std::uint8_t*>(value.data()), value.size()));
}

DocumentHandle make_document(std::string_view value, std::uint32_t id = 0) {
    return DocumentHandle(soda_document_create(reinterpret_cast<const std::uint8_t*>(value.data()),
                                               value.size(), id));
}

std::string copy_text(const soda_text* text) {
    const std::uint32_t size = soda_text_size(text);
    std::string result(size, '\0');
    if (size != 0) {
        REQUIRE(soda_text_copy(text, 0, size, reinterpret_cast<std::uint8_t*>(result.data()),
                               result.size()) == 0);
    }
    return result;
}

} // namespace

TEST_CASE("text ABI preserves bytes and coordinate queries") {
    CHECK(soda_document_abi_version() == SODA_DOCUMENT_ABI_VERSION);
    const TextHandle text = make_text("a\n\xF0\x9F\x98\x80");
    REQUIRE(text != nullptr);
    CHECK(soda_text_size(text.get()) == 6);
    CHECK(soda_text_line_count(text.get()) == 2);
    CHECK(soda_text_utf16_size(text.get()) == 4);
    CHECK(soda_text_line_start(text.get(), 1) == 2);
    CHECK(soda_text_offset(text.get(), 1, 4) == 6);
    CHECK(soda_text_utf16_offset(text.get(), 6) == 4);
    CHECK(soda_text_offset_at_utf16(text.get(), 3) == 6);

    std::uint32_t line = SODA_TEXT_NPOS;
    std::uint32_t column = SODA_TEXT_NPOS;
    REQUIRE(soda_text_position(text.get(), 6, &line, &column) == 0);
    CHECK(line == 1);
    CHECK(column == 4);
    CHECK(copy_text(text.get()) == "a\n\xF0\x9F\x98\x80");
}

TEST_CASE("document transaction exposes normalized changes and persistent snapshots") {
    DocumentHandle document = make_document("a\r\nb", 17);
    REQUIRE(document != nullptr);
    CHECK(soda_document_id(document.get()) == 17);
    CHECK(soda_document_revision(document.get()) == 0);

    SnapshotHandle before(soda_document_snapshot(document.get()));
    REQUIRE(before != nullptr);
    TransactionHandle transaction(soda_document_begin_transaction(document.get()));
    REQUIRE(transaction != nullptr);
    const std::array<std::uint8_t, 1> replacement{'c'};
    REQUIRE(soda_transaction_replace(transaction.get(), 2, 3, replacement.data(), 1) == 0);
    CHECK(soda_transaction_base_revision(transaction.get()) == 0);
    CHECK(soda_transaction_pending_edit_count(transaction.get()) == 1);
    std::uint32_t pending_start = SODA_TEXT_NPOS;
    std::uint32_t pending_end = SODA_TEXT_NPOS;
    REQUIRE(soda_transaction_pending_edit_range(transaction.get(), 0, &pending_start,
                                                &pending_end) == 0);
    CHECK(pending_start == 2);
    CHECK(pending_end == 3);
    CHECK(soda_transaction_pending_edit_text_size(transaction.get(), 0) == 1);
    std::array<std::uint8_t, 1> pending_text{};
    REQUIRE(soda_transaction_copy_pending_edit_text(transaction.get(), 0, pending_text.data(),
                                                    pending_text.size()) == 0);
    CHECK(pending_text[0] == 'c');

    SnapshotHandle speculative(soda_transaction_snapshot(transaction.get()));
    REQUIRE(speculative != nullptr);
    CHECK(soda_snapshot_revision(speculative.get()) == 1);
    TextHandle speculative_text(soda_snapshot_text(speculative.get()));
    CHECK(copy_text(speculative_text.get()) == "a\nc");

    ChangeHandle change(soda_transaction_commit(transaction.get()));
    REQUIRE(change != nullptr);
    CHECK(soda_change_old_revision(change.get()) == 0);
    CHECK(soda_change_new_revision(change.get()) == 1);
    CHECK(soda_change_edit_count(change.get()) == 1);
    std::uint32_t start = SODA_TEXT_NPOS;
    std::uint32_t end = SODA_TEXT_NPOS;
    REQUIRE(soda_change_edit_range(change.get(), 0, &start, &end) == 0);
    CHECK(start == 2);
    CHECK(end == 3);
    std::array<std::uint8_t, 1> edit_text{};
    REQUIRE(soda_change_copy_edit_text(change.get(), 0, edit_text.data(), edit_text.size()) == 0);
    CHECK(edit_text[0] == 'c');
    CHECK(soda_document_revision(document.get()) == 1);

    TextHandle before_text(soda_snapshot_text(before.get()));
    CHECK(copy_text(before_text.get()) == "a\nb");
}

TEST_CASE("undo anchors and transaction ownership survive ABI handle lifetimes") {
    DocumentHandle document = make_document("ab");
    REQUIRE(document != nullptr);
    const std::uint32_t anchor =
        soda_document_create_anchor(document.get(), 1, SODA_ANCHOR_AFTER_INSERTION);
    REQUIRE(anchor != 0);

    TransactionHandle transaction(soda_document_begin_transaction(document.get()));
    REQUIRE(transaction != nullptr);
    const std::array<std::uint8_t, 1> inserted{'x'};
    REQUIRE(soda_transaction_insert(transaction.get(), 1, inserted.data(), inserted.size()) == 0);
    CHECK(soda_transaction_anchor_offset(transaction.get(), anchor) == 2);

    document.reset();
    ChangeHandle change(soda_transaction_commit(transaction.get()));
    REQUIRE(change != nullptr);
    CHECK(soda_change_new_revision(change.get()) == 1);

    DocumentHandle undo_document = make_document("ab");
    REQUIRE(undo_document != nullptr);
    CHECK(soda_document_undo(undo_document.get()) == nullptr);
    CHECK(std::strlen(soda_document_last_error()) == 0);
    TransactionHandle edit(soda_document_begin_transaction(undo_document.get()));
    REQUIRE(edit != nullptr);
    REQUIRE(soda_transaction_insert(edit.get(), 2, inserted.data(), inserted.size()) == 0);
    ChangeHandle committed(soda_transaction_commit(edit.get()));
    REQUIRE(committed != nullptr);
    ChangeHandle undone(soda_document_undo(undo_document.get()));
    REQUIRE(undone != nullptr);
    CHECK(soda_document_can_redo(undo_document.get()) == 1);
}

TEST_CASE("ABI failures are conditions rather than exceptions across C") {
    const TextHandle text = make_text("a");
    REQUIRE(text != nullptr);
    CHECK(soda_text_line_start(text.get(), 8) == SODA_TEXT_NPOS);
    CHECK(std::strlen(soda_document_last_error()) != 0);

    const DocumentHandle document = make_document("abc");
    REQUIRE(document != nullptr);
    CHECK(soda_document_create_anchor(document.get(), 9, SODA_ANCHOR_BEFORE_INSERTION) == 0);
    CHECK(std::strlen(soda_document_last_error()) != 0);
}
