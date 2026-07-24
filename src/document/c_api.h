#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(SODA_DOCUMENT_BUILD)
#define SODA_DOCUMENT_API __declspec(dllexport)
#else
#define SODA_DOCUMENT_API __declspec(dllimport)
#endif
#else
#define SODA_DOCUMENT_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct soda_text soda_text;
typedef struct soda_document soda_document;
typedef struct soda_snapshot soda_snapshot;
typedef struct soda_transaction soda_transaction;
typedef struct soda_change soda_change;

#define SODA_DOCUMENT_ABI_VERSION 1U
#define SODA_TEXT_NPOS UINT32_MAX
#define SODA_UNDO_NODE_NONE UINT32_MAX

#define SODA_ANCHOR_BEFORE_INSERTION 0
#define SODA_ANCHOR_AFTER_INSERTION 1

// The message is local to the calling thread. Every fallible document ABI
// operation replaces it; an empty message means the operation had no error.
SODA_DOCUMENT_API uint32_t soda_document_abi_version(void);
SODA_DOCUMENT_API const char* soda_document_last_error(void);

SODA_DOCUMENT_API soda_text* soda_text_create(const uint8_t* data, size_t size);
SODA_DOCUMENT_API soda_text* soda_text_clone(const soda_text* text);
SODA_DOCUMENT_API void soda_text_destroy(soda_text* text);
SODA_DOCUMENT_API uint32_t soda_text_size(const soda_text* text);
SODA_DOCUMENT_API uint32_t soda_text_line_count(const soda_text* text);
SODA_DOCUMENT_API uint32_t soda_text_utf16_size(const soda_text* text);
SODA_DOCUMENT_API int soda_text_copy(const soda_text* text, uint32_t start, uint32_t end,
                                     uint8_t* destination, size_t capacity);
SODA_DOCUMENT_API int soda_text_byte_at(const soda_text* text, uint32_t offset);
SODA_DOCUMENT_API uint32_t soda_text_line_start(const soda_text* text, uint32_t line);
SODA_DOCUMENT_API uint32_t soda_text_line_content_end(const soda_text* text, uint32_t line);
SODA_DOCUMENT_API int soda_text_position(const soda_text* text, uint32_t offset, uint32_t* line,
                                         uint32_t* byte_column);
SODA_DOCUMENT_API uint32_t soda_text_offset(const soda_text* text, uint32_t line,
                                            uint32_t byte_column);
SODA_DOCUMENT_API uint32_t soda_text_utf16_offset(const soda_text* text, uint32_t offset);
SODA_DOCUMENT_API uint32_t soda_text_offset_at_utf16(const soda_text* text, uint32_t utf16_offset);

SODA_DOCUMENT_API soda_document* soda_document_create(const uint8_t* data, size_t size,
                                                      uint32_t document_id);
SODA_DOCUMENT_API soda_document* soda_document_create_from_text(const soda_text* text,
                                                                uint32_t document_id);
SODA_DOCUMENT_API void soda_document_destroy(soda_document* document);
SODA_DOCUMENT_API uint32_t soda_document_id(const soda_document* document);
SODA_DOCUMENT_API uint64_t soda_document_revision(const soda_document* document);
SODA_DOCUMENT_API soda_snapshot* soda_document_snapshot(const soda_document* document);
SODA_DOCUMENT_API soda_transaction* soda_document_begin_transaction(soda_document* document);

SODA_DOCUMENT_API int soda_document_can_undo(const soda_document* document);
SODA_DOCUMENT_API int soda_document_can_redo(const soda_document* document);
// A null result with an empty last-error message means no undo or redo was
// available.
SODA_DOCUMENT_API soda_change* soda_document_undo(soda_document* document);
SODA_DOCUMENT_API soda_change* soda_document_redo(soda_document* document);
SODA_DOCUMENT_API soda_change* soda_document_undo_to(soda_document* document, uint32_t undo_node);
SODA_DOCUMENT_API uint32_t soda_document_undo_position(const soda_document* document);
SODA_DOCUMENT_API uint32_t soda_document_undo_node_count(const soda_document* document);
SODA_DOCUMENT_API uint32_t soda_document_undo_parent(const soda_document* document,
                                                     uint32_t undo_node);
SODA_DOCUMENT_API uint32_t soda_document_undo_child_count(const soda_document* document,
                                                          uint32_t undo_node);
SODA_DOCUMENT_API uint32_t soda_document_undo_child(const soda_document* document,
                                                    uint32_t undo_node, uint32_t child_index);

SODA_DOCUMENT_API uint32_t soda_document_create_anchor(soda_document* document, uint32_t offset,
                                                       int affinity);
SODA_DOCUMENT_API int soda_document_remove_anchor(soda_document* document, uint32_t anchor);
SODA_DOCUMENT_API uint32_t soda_document_anchor_offset(const soda_document* document,
                                                       uint32_t anchor);
SODA_DOCUMENT_API int soda_document_anchor_affinity(const soda_document* document, uint32_t anchor);
SODA_DOCUMENT_API int soda_document_set_anchor_affinity(soda_document* document, uint32_t anchor,
                                                        int affinity);
// SODA_TEXT_NPOS clears the editable boundary.
SODA_DOCUMENT_API int soda_document_set_editable_start(soda_document* document, uint32_t offset);
// Returns SODA_TEXT_NPOS when the document has no editable boundary. Check
// soda_document_last_error to distinguish that value from an error.
SODA_DOCUMENT_API uint32_t soda_document_editable_start(const soda_document* document);

SODA_DOCUMENT_API void soda_snapshot_destroy(soda_snapshot* snapshot);
SODA_DOCUMENT_API uint32_t soda_snapshot_document_id(const soda_snapshot* snapshot);
SODA_DOCUMENT_API uint64_t soda_snapshot_revision(const soda_snapshot* snapshot);
SODA_DOCUMENT_API soda_text* soda_snapshot_text(const soda_snapshot* snapshot);

SODA_DOCUMENT_API void soda_transaction_destroy(soda_transaction* transaction);
SODA_DOCUMENT_API int soda_transaction_replace(soda_transaction* transaction, uint32_t start,
                                               uint32_t end, const uint8_t* replacement,
                                               size_t replacement_size);
SODA_DOCUMENT_API int soda_transaction_insert(soda_transaction* transaction, uint32_t offset,
                                              const uint8_t* text, size_t size);
SODA_DOCUMENT_API int soda_transaction_erase(soda_transaction* transaction, uint32_t start,
                                             uint32_t end);
SODA_DOCUMENT_API uint32_t soda_transaction_anchor_offset(const soda_transaction* transaction,
                                                          uint32_t anchor);
SODA_DOCUMENT_API int soda_transaction_set_anchor_affinity(soda_transaction* transaction,
                                                           uint32_t anchor, int affinity);
SODA_DOCUMENT_API soda_snapshot* soda_transaction_snapshot(const soda_transaction* transaction);
SODA_DOCUMENT_API soda_change* soda_transaction_commit(soda_transaction* transaction);
SODA_DOCUMENT_API int soda_transaction_abort(soda_transaction* transaction);

SODA_DOCUMENT_API void soda_change_destroy(soda_change* change);
SODA_DOCUMENT_API uint64_t soda_change_old_revision(const soda_change* change);
SODA_DOCUMENT_API uint64_t soda_change_new_revision(const soda_change* change);
SODA_DOCUMENT_API uint32_t soda_change_edit_count(const soda_change* change);
SODA_DOCUMENT_API int soda_change_edit_range(const soda_change* change, uint32_t edit_index,
                                             uint32_t* start, uint32_t* end);
SODA_DOCUMENT_API uint32_t soda_change_edit_start(const soda_change* change, uint32_t edit_index);
SODA_DOCUMENT_API uint32_t soda_change_edit_end(const soda_change* change, uint32_t edit_index);
SODA_DOCUMENT_API uint32_t soda_change_edit_text_size(const soda_change* change,
                                                      uint32_t edit_index);
SODA_DOCUMENT_API int soda_change_copy_edit_text(const soda_change* change, uint32_t edit_index,
                                                 uint8_t* destination, size_t capacity);
SODA_DOCUMENT_API int soda_change_affected_old_range(const soda_change* change, uint32_t* start,
                                                     uint32_t* end);
SODA_DOCUMENT_API int soda_change_affected_new_range(const soda_change* change, uint32_t* start,
                                                     uint32_t* end);
SODA_DOCUMENT_API uint32_t soda_change_affected_old_start(const soda_change* change);
SODA_DOCUMENT_API uint32_t soda_change_affected_old_end(const soda_change* change);
SODA_DOCUMENT_API uint32_t soda_change_affected_new_start(const soda_change* change);
SODA_DOCUMENT_API uint32_t soda_change_affected_new_end(const soda_change* change);

#ifdef __cplusplus
}
#endif
