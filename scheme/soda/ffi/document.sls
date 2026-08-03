(library (soda ffi document)
  (export text-npos
          revision-none
          undo-node-none
          anchor-before-insertion
          anchor-after-insertion
          %last-error
          %text-create
          %text-destroy
          %text-size
          %text-line-count
          %text-utf16-size
          %text-copy
          %text-byte-at
          %text-line-start
          %text-line-content-end
          %text-position
          %text-offset
          %text-utf16-offset
          %text-offset-at-utf16
          %document-create
          %document-create-from-text
          %document-destroy
          %document-id
          %document-revision
          %document-snapshot
          %document-begin
          %document-can-undo
          %document-can-redo
          %document-undo
          %document-redo
          %document-undo-to
          %document-undo-position
          %document-undo-node-count
          %document-undo-parent
          %document-undo-child-count
          %document-undo-child
          %document-create-anchor
          %document-remove-anchor
          %document-anchor-offset
          %document-anchor-affinity
          %document-set-anchor-affinity
          %document-editable-start
          %document-set-editable-start
          %snapshot-destroy
          %snapshot-document-id
          %snapshot-revision
          %snapshot-text
          %transaction-destroy
          %transaction-replace
          %transaction-insert
          %transaction-erase
          %transaction-anchor-offset
          %transaction-set-anchor-affinity
          %transaction-base-revision
          %transaction-pending-edit-count
          %transaction-pending-edit-range
          %transaction-pending-edit-text-size
          %transaction-copy-pending-edit-text
          %transaction-snapshot
          %transaction-commit
          %transaction-abort
          %change-destroy
          %change-old-revision
          %change-new-revision
          %change-edit-count
          %change-edit-start
          %change-edit-end
          %change-edit-text-size
          %change-copy-edit-text
          %change-affected-old-start
          %change-affected-old-end
          %change-affected-new-start
          %change-affected-new-end
          native-error
          check-status)
  (import (chezscheme)
          (soda ffi helpers))

  (define text-npos #xffffffff)
  (define revision-none #xffffffffffffffff)
  (define undo-node-none #xffffffff)
  (define anchor-before-insertion 0)
  (define anchor-after-insertion 1)

  (define %abi-version
    (foreign-procedure __atomic "soda_document_abi_version" () unsigned-32))
  (define %last-error
    (foreign-procedure __atomic "soda_document_last_error" () string))

  (define abi-version-checked
    (unless (= (%abi-version) 2)
      (error 'soda-document "unsupported native document ABI version")))

  (define %text-create
    (foreign-procedure __atomic "soda_text_create" (u8* size_t) void*))
  (define %text-destroy
    (foreign-procedure __atomic "soda_text_destroy" (void*) void))
  (define %text-size
    (foreign-procedure __atomic "soda_text_size" (void*) unsigned-32))
  (define %text-line-count
    (foreign-procedure __atomic "soda_text_line_count" (void*) unsigned-32))
  (define %text-utf16-size
    (foreign-procedure __atomic "soda_text_utf16_size" (void*) unsigned-32))
  (define %text-copy
    (foreign-procedure __atomic "soda_text_copy"
                       (void* unsigned-32 unsigned-32 u8* size_t)
                       int))
  (define %text-byte-at
    (foreign-procedure __atomic "soda_text_byte_at" (void* unsigned-32) int))
  (define %text-line-start
    (foreign-procedure __atomic "soda_text_line_start"
                       (void* unsigned-32)
                       unsigned-32))
  (define %text-line-content-end
    (foreign-procedure __atomic "soda_text_line_content_end"
                       (void* unsigned-32)
                       unsigned-32))
  (define %text-position
    (foreign-procedure __atomic "soda_text_position"
                       (void* unsigned-32 void* void*)
                       int))
  (define %text-offset
    (foreign-procedure __atomic "soda_text_offset"
                       (void* unsigned-32 unsigned-32)
                       unsigned-32))
  (define %text-utf16-offset
    (foreign-procedure __atomic "soda_text_utf16_offset"
                       (void* unsigned-32)
                       unsigned-32))
  (define %text-offset-at-utf16
    (foreign-procedure __atomic "soda_text_offset_at_utf16"
                       (void* unsigned-32)
                       unsigned-32))

  (define %document-create
    (foreign-procedure __atomic "soda_document_create"
                       (u8* size_t unsigned-32)
                       void*))
  (define %document-create-from-text
    (foreign-procedure __atomic "soda_document_create_from_text"
                       (void* unsigned-32)
                       void*))
  (define %document-destroy
    (foreign-procedure __atomic "soda_document_destroy" (void*) void))
  (define %document-id
    (foreign-procedure __atomic "soda_document_id" (void*) unsigned-32))
  (define %document-revision
    (foreign-procedure __atomic "soda_document_revision" (void*) unsigned-64))
  (define %document-snapshot
    (foreign-procedure __atomic "soda_document_snapshot" (void*) void*))
  (define %document-begin
    (foreign-procedure __atomic "soda_document_begin_transaction" (void*) void*))
  (define %document-can-undo
    (foreign-procedure __atomic "soda_document_can_undo" (void*) int))
  (define %document-can-redo
    (foreign-procedure __atomic "soda_document_can_redo" (void*) int))
  (define %document-undo
    (foreign-procedure __atomic "soda_document_undo" (void*) void*))
  (define %document-redo
    (foreign-procedure __atomic "soda_document_redo" (void*) void*))
  (define %document-undo-to
    (foreign-procedure __atomic "soda_document_undo_to"
                       (void* unsigned-32)
                       void*))
  (define %document-undo-position
    (foreign-procedure __atomic "soda_document_undo_position" (void*) unsigned-32))
  (define %document-undo-node-count
    (foreign-procedure __atomic "soda_document_undo_node_count" (void*) unsigned-32))
  (define %document-undo-parent
    (foreign-procedure __atomic "soda_document_undo_parent"
                       (void* unsigned-32)
                       unsigned-32))
  (define %document-undo-child-count
    (foreign-procedure __atomic "soda_document_undo_child_count"
                       (void* unsigned-32)
                       unsigned-32))
  (define %document-undo-child
    (foreign-procedure __atomic "soda_document_undo_child"
                       (void* unsigned-32 unsigned-32)
                       unsigned-32))
  (define %document-create-anchor
    (foreign-procedure __atomic "soda_document_create_anchor"
                       (void* unsigned-32 int)
                       unsigned-32))
  (define %document-remove-anchor
    (foreign-procedure __atomic "soda_document_remove_anchor"
                       (void* unsigned-32)
                       int))
  (define %document-anchor-offset
    (foreign-procedure __atomic "soda_document_anchor_offset"
                       (void* unsigned-32)
                       unsigned-32))
  (define %document-anchor-affinity
    (foreign-procedure __atomic "soda_document_anchor_affinity"
                       (void* unsigned-32)
                       int))
  (define %document-set-anchor-affinity
    (foreign-procedure __atomic "soda_document_set_anchor_affinity"
                       (void* unsigned-32 int)
                       int))
  (define %document-editable-start
    (foreign-procedure __atomic "soda_document_editable_start" (void*) unsigned-32))
  (define %document-set-editable-start
    (foreign-procedure __atomic "soda_document_set_editable_start"
                       (void* unsigned-32)
                       int))

  (define %snapshot-destroy
    (foreign-procedure __atomic "soda_snapshot_destroy" (void*) void))
  (define %snapshot-document-id
    (foreign-procedure __atomic "soda_snapshot_document_id" (void*) unsigned-32))
  (define %snapshot-revision
    (foreign-procedure __atomic "soda_snapshot_revision" (void*) unsigned-64))
  (define %snapshot-text
    (foreign-procedure __atomic "soda_snapshot_text" (void*) void*))

  (define %transaction-destroy
    (foreign-procedure __atomic "soda_transaction_destroy" (void*) void))
  (define %transaction-replace
    (foreign-procedure __atomic "soda_transaction_replace"
                       (void* unsigned-32 unsigned-32 u8* size_t)
                       int))
  (define %transaction-insert
    (foreign-procedure __atomic "soda_transaction_insert"
                       (void* unsigned-32 u8* size_t)
                       int))
  (define %transaction-erase
    (foreign-procedure __atomic "soda_transaction_erase"
                       (void* unsigned-32 unsigned-32)
                       int))
  (define %transaction-anchor-offset
    (foreign-procedure __atomic "soda_transaction_anchor_offset"
                       (void* unsigned-32)
                       unsigned-32))
  (define %transaction-set-anchor-affinity
    (foreign-procedure __atomic "soda_transaction_set_anchor_affinity"
                       (void* unsigned-32 int)
                       int))
  (define %transaction-base-revision
    (foreign-procedure __atomic "soda_transaction_base_revision"
                       (void*)
                       unsigned-64))
  (define %transaction-pending-edit-count
    (foreign-procedure __atomic "soda_transaction_pending_edit_count"
                       (void*)
                       unsigned-32))
  (define %transaction-pending-edit-range
    (foreign-procedure __atomic "soda_transaction_pending_edit_range"
                       (void* unsigned-32 void* void*)
                       int))
  (define %transaction-pending-edit-text-size
    (foreign-procedure __atomic "soda_transaction_pending_edit_text_size"
                       (void* unsigned-32)
                       unsigned-32))
  (define %transaction-copy-pending-edit-text
    (foreign-procedure __atomic "soda_transaction_copy_pending_edit_text"
                       (void* unsigned-32 u8* size_t)
                       int))
  (define %transaction-snapshot
    (foreign-procedure __atomic "soda_transaction_snapshot" (void*) void*))
  (define %transaction-commit
    (foreign-procedure __atomic "soda_transaction_commit" (void*) void*))
  (define %transaction-abort
    (foreign-procedure __atomic "soda_transaction_abort" (void*) int))

  (define %change-destroy
    (foreign-procedure __atomic "soda_change_destroy" (void*) void))
  (define %change-old-revision
    (foreign-procedure __atomic "soda_change_old_revision" (void*) unsigned-64))
  (define %change-new-revision
    (foreign-procedure __atomic "soda_change_new_revision" (void*) unsigned-64))
  (define %change-edit-count
    (foreign-procedure __atomic "soda_change_edit_count" (void*) unsigned-32))
  (define %change-edit-start
    (foreign-procedure __atomic "soda_change_edit_start"
                       (void* unsigned-32)
                       unsigned-32))
  (define %change-edit-end
    (foreign-procedure __atomic "soda_change_edit_end"
                       (void* unsigned-32)
                       unsigned-32))
  (define %change-edit-text-size
    (foreign-procedure __atomic "soda_change_edit_text_size"
                       (void* unsigned-32)
                       unsigned-32))
  (define %change-copy-edit-text
    (foreign-procedure __atomic "soda_change_copy_edit_text"
                       (void* unsigned-32 u8* size_t)
                       int))
  (define %change-affected-old-start
    (foreign-procedure __atomic "soda_change_affected_old_start" (void*) unsigned-32))
  (define %change-affected-old-end
    (foreign-procedure __atomic "soda_change_affected_old_end" (void*) unsigned-32))
  (define %change-affected-new-start
    (foreign-procedure __atomic "soda_change_affected_new_start" (void*) unsigned-32))
  (define %change-affected-new-end
    (foreign-procedure __atomic "soda_change_affected_new_end" (void*) unsigned-32))

  (define native-error (make-native-error %last-error))
  (define check-status (make-native-status-checker native-error)))
