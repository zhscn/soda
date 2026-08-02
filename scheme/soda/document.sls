(library (soda document)
  (export bytevector->text
          string->text
          text?
          text-close!
          text-size
          text-line-count
          text-utf16-size
          text->bytevector
          text-subbytevector
          text-byte-at
          text-previous-character-offset
          text-next-character-offset
          text-line-start
          text-line-content-end
          text-position
          text-offset
          text-utf16-offset
          text-offset-at-utf16
          make-document
          text->document
          document?
          document-close!
          document-id
          document-revision
          document-snapshot
          call-with-document-snapshot-text
          call-with-document-text
          document-byte-size
          document-begin-transaction
          document-can-undo?
          document-can-redo?
          document-undo!
          document-redo!
          document-undo-to!
          document-undo-position
          document-undo-node-count
          document-undo-parent
          document-undo-children
          document-create-anchor!
          document-remove-anchor!
          document-anchor-offset
          document-anchor-affinity
          document-set-anchor-affinity!
          document-editable-start
          document-set-editable-start!
          snapshot?
          snapshot-close!
          snapshot-document-id
          snapshot-revision
          snapshot-text
          snapshot-byte-size
          transaction?
          transaction-close!
          transaction-replace!
          transaction-insert!
          transaction-erase!
          transaction-anchor-offset
          transaction-set-anchor-affinity!
          transaction-base-revision
          transaction-pending-edit-count
          transaction-pending-edit-range
          transaction-pending-edit-text
          transaction-snapshot
          transaction-commit!
          transaction-abort!
          change?
          change-close!
          change-old-revision
          change-new-revision
          change-edit-count
          change-edit-range
          change-edit-text
          change-affected-old-range
          change-affected-new-range
          anchor-before-insertion
          anchor-after-insertion)
  (import (chezscheme)
          (soda native)
          (soda document handles))

  (define native-library-loaded
    (load-soda-native-library! "SODA_DOCUMENT_LIBRARY"))

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

  (define (native-error who)
    (error who (%last-error)))

  (define (null-pointer? pointer)
    (or (not pointer)
        (and (integer? pointer) (zero? pointer))))

  (define (check-status who status)
    (when (negative? status)
      (native-error who)))

  (define (check-pointer who pointer)
    (when (null-pointer? pointer)
      (native-error who))
    pointer)

  (define (check-revision who revision)
    (if (= revision revision-none)
        (native-error who)
        revision))

  (define (as-bytevector who value)
    (cond
      [(bytevector? value) value]
      [(string? value) (string->utf8 value)]
      [else (assertion-violation who "expected a bytevector or string" value)]))

  (define (require-open who predicate pointer value)
    (unless (predicate value)
      (assertion-violation who "unexpected handle type" value))
    (when (null-pointer? (pointer value))
      (assertion-violation who "handle is closed" value)))

  (define (bytevector->text data)
    (let ([data (as-bytevector 'bytevector->text data)])
      (%make-text
        (check-pointer 'bytevector->text
                       (%text-create data (bytevector-length data))))))

  (define (string->text value)
    (bytevector->text (as-bytevector 'string->text value)))

  (define (text-close! value)
    (when (and (text? value)
               (not (null-pointer? (text-pointer value))))
      (%text-destroy (text-pointer value))
      (text-pointer-set! value #f)))

  (define (text-size value)
    (require-open 'text-size text? text-pointer value)
    (let ([size (%text-size (text-pointer value))])
      (if (= size text-npos) (native-error 'text-size) size)))

  (define (text-line-count value)
    (require-open 'text-line-count text? text-pointer value)
    (let ([count (%text-line-count (text-pointer value))])
      (if (zero? count) (native-error 'text-line-count) count)))

  (define (text-utf16-size value)
    (require-open 'text-utf16-size text? text-pointer value)
    (let ([size (%text-utf16-size (text-pointer value))])
      (if (= size text-npos) (native-error 'text-utf16-size) size)))

  (define (text-subbytevector value start end)
    (require-open 'text-subbytevector text? text-pointer value)
    (when (> start end)
      (assertion-violation 'text-subbytevector "start is greater than end" start end))
    (let ([output (make-bytevector (- end start))])
      (check-status
        'text-subbytevector
        (%text-copy (text-pointer value) start end output (bytevector-length output)))
      output))

  (define (text->bytevector value)
    (text-subbytevector value 0 (text-size value)))

  (define (text-byte-at value offset)
    (require-open 'text-byte-at text? text-pointer value)
    (let ([byte (%text-byte-at (text-pointer value) offset)])
      (if (negative? byte) (native-error 'text-byte-at) byte)))

  (define (text-previous-character-offset value offset)
    (if (zero? offset)
        0
        (let loop ([candidate (- offset 1)])
          (if (or
                (zero? candidate)
                (not
                  (= (bitwise-and
                       (text-byte-at value candidate)
                       #xc0)
                     #x80)))
              candidate
              (loop (- candidate 1))))))

  (define (text-next-character-offset value offset)
    (let ([size (text-size value)])
      (if (>= offset size)
          size
          (let loop ([candidate (+ offset 1)])
            (if (or
                  (>= candidate size)
                  (not
                    (= (bitwise-and
                         (text-byte-at value candidate)
                         #xc0)
                       #x80)))
                candidate
                (loop (+ candidate 1)))))))

  (define (checked-text-offset who operation)
    (let ([offset (operation)])
      (if (= offset text-npos) (native-error who) offset)))

  (define (text-line-start value line)
    (require-open 'text-line-start text? text-pointer value)
    (checked-text-offset
      'text-line-start
      (lambda () (%text-line-start (text-pointer value) line))))

  (define (text-line-content-end value line)
    (require-open 'text-line-content-end text? text-pointer value)
    (checked-text-offset
      'text-line-content-end
      (lambda () (%text-line-content-end (text-pointer value) line))))

  (define (text-position value offset)
    (require-open 'text-position text? text-pointer value)
    (let ([line (foreign-alloc 4)]
          [column (foreign-alloc 4)])
      (dynamic-wind
        (lambda () (void))
        (lambda ()
          (check-status
            'text-position
            (%text-position (text-pointer value) offset line column))
          (cons (foreign-ref 'unsigned-32 line 0)
                (foreign-ref 'unsigned-32 column 0)))
        (lambda ()
          (foreign-free line)
          (foreign-free column)))))

  (define (text-offset value line byte-column)
    (require-open 'text-offset text? text-pointer value)
    (checked-text-offset
      'text-offset
      (lambda () (%text-offset (text-pointer value) line byte-column))))

  (define (text-utf16-offset value offset)
    (require-open 'text-utf16-offset text? text-pointer value)
    (checked-text-offset
      'text-utf16-offset
      (lambda () (%text-utf16-offset (text-pointer value) offset))))

  (define (text-offset-at-utf16 value offset)
    (require-open 'text-offset-at-utf16 text? text-pointer value)
    (checked-text-offset
      'text-offset-at-utf16
      (lambda () (%text-offset-at-utf16 (text-pointer value) offset))))

  (define make-document
    (case-lambda
      [(data) (make-document data 0)]
      [(data id)
       (let ([data (as-bytevector 'make-document data)])
         (%make-document
           (check-pointer
             'make-document
             (%document-create data (bytevector-length data) id))))]))

  (define make-document-from-text
    (lambda (value id)
      (require-open 'text->document text? text-pointer value)
      (%make-document
        (check-pointer
          'text->document
          (%document-create-from-text (text-pointer value) id)))))

  (define text->document
    (case-lambda
      [(value) (make-document-from-text value 0)]
      [(value id) (make-document-from-text value id)]))

  (define (document-close! value)
    (when (and (document? value)
               (not (null-pointer? (document-pointer value))))
      (%document-destroy (document-pointer value))
      (document-pointer-set! value #f)))

  (define (document-id value)
    (require-open 'document-id document? document-pointer value)
    (%document-id (document-pointer value)))

  (define (document-revision value)
    (require-open 'document-revision document? document-pointer value)
    (check-revision
      'document-revision
      (%document-revision (document-pointer value))))

  (define (document-snapshot value)
    (require-open 'document-snapshot document? document-pointer value)
    (%make-snapshot
      (check-pointer 'document-snapshot
                     (%document-snapshot (document-pointer value)))))

  (define (document-begin-transaction value)
    (require-open 'document-begin-transaction document? document-pointer value)
    (%make-transaction
      (check-pointer 'document-begin-transaction
                     (%document-begin (document-pointer value)))))

  (define (native-boolean who value)
    (if (negative? value) (native-error who) (not (zero? value))))

  (define (document-can-undo? value)
    (require-open 'document-can-undo? document? document-pointer value)
    (native-boolean 'document-can-undo?
                    (%document-can-undo (document-pointer value))))

  (define (document-can-redo? value)
    (require-open 'document-can-redo? document? document-pointer value)
    (native-boolean 'document-can-redo?
                    (%document-can-redo (document-pointer value))))

  (define (optional-change who pointer)
    (if (null-pointer? pointer)
        (let ([message (%last-error)])
          (if (string=? message "") #f (error who message)))
        (%make-change pointer)))

  (define (document-undo! value)
    (require-open 'document-undo! document? document-pointer value)
    (optional-change 'document-undo! (%document-undo (document-pointer value))))

  (define (document-redo! value)
    (require-open 'document-redo! document? document-pointer value)
    (optional-change 'document-redo! (%document-redo (document-pointer value))))

  (define (document-undo-to! value node)
    (require-open 'document-undo-to! document? document-pointer value)
    (%make-change
      (check-pointer 'document-undo-to!
                     (%document-undo-to (document-pointer value) node))))

  (define (document-undo-position value)
    (require-open 'document-undo-position document? document-pointer value)
    (%document-undo-position (document-pointer value)))

  (define (document-undo-node-count value)
    (require-open 'document-undo-node-count document? document-pointer value)
    (%document-undo-node-count (document-pointer value)))

  (define (document-undo-parent value node)
    (require-open 'document-undo-parent document? document-pointer value)
    (let ([parent (%document-undo-parent (document-pointer value) node)])
      (if (= parent undo-node-none)
          (let ([message (%last-error)])
            (if (string=? message "") #f (error 'document-undo-parent message)))
          parent)))

  (define (document-undo-children value node)
    (require-open 'document-undo-children document? document-pointer value)
    (let* ([count (%document-undo-child-count (document-pointer value) node)]
           [message (%last-error)])
      (unless (string=? message "")
        (error 'document-undo-children message))
      (do ([index 0 (+ index 1)]
           [children '()
                     (let ([child (%document-undo-child
                                    (document-pointer value)
                                    node
                                    index)])
                       (if (= child undo-node-none)
                           (native-error 'document-undo-children)
                           (cons child children)))])
          ((= index count) (reverse children)))))

  (define (document-create-anchor! value offset affinity)
    (require-open 'document-create-anchor! document? document-pointer value)
    (let ([anchor (%document-create-anchor (document-pointer value) offset affinity)])
      (if (zero? anchor) (native-error 'document-create-anchor!) anchor)))

  (define (document-remove-anchor! value anchor)
    (require-open 'document-remove-anchor! document? document-pointer value)
    (check-status 'document-remove-anchor!
                  (%document-remove-anchor (document-pointer value) anchor)))

  (define (document-anchor-offset value anchor)
    (require-open 'document-anchor-offset document? document-pointer value)
    (checked-text-offset
      'document-anchor-offset
      (lambda () (%document-anchor-offset (document-pointer value) anchor))))

  (define (document-anchor-affinity value anchor)
    (require-open 'document-anchor-affinity document? document-pointer value)
    (let ([affinity (%document-anchor-affinity (document-pointer value) anchor)])
      (if (negative? affinity) (native-error 'document-anchor-affinity) affinity)))

  (define (document-set-anchor-affinity! value anchor affinity)
    (require-open 'document-set-anchor-affinity! document? document-pointer value)
    (check-status
      'document-set-anchor-affinity!
      (%document-set-anchor-affinity (document-pointer value) anchor affinity)))

  (define (document-editable-start value)
    (require-open 'document-editable-start document? document-pointer value)
    (let ([offset (%document-editable-start (document-pointer value))])
      (if (= offset text-npos)
          (let ([message (%last-error)])
            (if (string=? message "") #f (error 'document-editable-start message)))
          offset)))

  (define (document-set-editable-start! value offset)
    (require-open 'document-set-editable-start! document? document-pointer value)
    (check-status
      'document-set-editable-start!
      (%document-set-editable-start
        (document-pointer value)
        (if offset offset text-npos))))

  (define (snapshot-close! value)
    (when (and (snapshot? value)
               (not (null-pointer? (snapshot-pointer value))))
      (%snapshot-destroy (snapshot-pointer value))
      (snapshot-pointer-set! value #f)))

  (define (snapshot-document-id value)
    (require-open 'snapshot-document-id snapshot? snapshot-pointer value)
    (%snapshot-document-id (snapshot-pointer value)))

  (define (snapshot-revision value)
    (require-open 'snapshot-revision snapshot? snapshot-pointer value)
    (check-revision
      'snapshot-revision
      (%snapshot-revision (snapshot-pointer value))))

  (define (snapshot-text value)
    (require-open 'snapshot-text snapshot? snapshot-pointer value)
    (%make-text
      (check-pointer 'snapshot-text (%snapshot-text (snapshot-pointer value)))))

  (define (call-with-document-snapshot-text document procedure)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-document-snapshot-text
        "expected a procedure"
        procedure))
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure snapshot text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (call-with-document-text document procedure)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-document-text "expected a procedure" procedure))
    (call-with-document-snapshot-text
      document
      (lambda (snapshot text) (procedure text))))

  (define (document-byte-size document)
    (call-with-document-text document text-size))

  (define (snapshot-byte-size snapshot)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda () (text-size text))
        (lambda () (text-close! text)))))

  (define (transaction-close! value)
    (when (and (transaction? value)
               (not (null-pointer? (transaction-pointer value))))
      (%transaction-destroy (transaction-pointer value))
      (transaction-pointer-set! value #f)))

  (define (transaction-replace! value start end replacement)
    (require-open 'transaction-replace! transaction? transaction-pointer value)
    (let ([replacement (as-bytevector 'transaction-replace! replacement)])
      (check-status
        'transaction-replace!
        (%transaction-replace (transaction-pointer value)
                              start
                              end
                              replacement
                              (bytevector-length replacement)))))

  (define (transaction-insert! value offset inserted)
    (require-open 'transaction-insert! transaction? transaction-pointer value)
    (let ([inserted (as-bytevector 'transaction-insert! inserted)])
      (check-status
        'transaction-insert!
        (%transaction-insert (transaction-pointer value)
                             offset
                             inserted
                             (bytevector-length inserted)))))

  (define (transaction-erase! value start end)
    (require-open 'transaction-erase! transaction? transaction-pointer value)
    (check-status 'transaction-erase!
                  (%transaction-erase (transaction-pointer value) start end)))

  (define (transaction-anchor-offset value anchor)
    (require-open 'transaction-anchor-offset transaction? transaction-pointer value)
    (checked-text-offset
      'transaction-anchor-offset
      (lambda () (%transaction-anchor-offset (transaction-pointer value) anchor))))

  (define (transaction-set-anchor-affinity! value anchor affinity)
    (require-open
      'transaction-set-anchor-affinity!
      transaction?
      transaction-pointer
      value)
    (check-status
      'transaction-set-anchor-affinity!
      (%transaction-set-anchor-affinity
        (transaction-pointer value)
        anchor
        affinity)))

  (define (transaction-base-revision value)
    (require-open
      'transaction-base-revision
      transaction?
      transaction-pointer
      value)
    (let ([revision (%transaction-base-revision (transaction-pointer value))])
      (if (= revision revision-none)
          (native-error 'transaction-base-revision)
          revision)))

  (define (transaction-pending-edit-count value)
    (require-open
      'transaction-pending-edit-count
      transaction?
      transaction-pointer
      value)
    (let ([count
            (%transaction-pending-edit-count (transaction-pointer value))])
      (if (= count text-npos)
          (native-error 'transaction-pending-edit-count)
          count)))

  (define (transaction-pending-edit-range value index)
    (require-open
      'transaction-pending-edit-range
      transaction?
      transaction-pointer
      value)
    (let ([start (foreign-alloc 4)]
          [end (foreign-alloc 4)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (check-status
            'transaction-pending-edit-range
            (%transaction-pending-edit-range
              (transaction-pointer value)
              index
              start
              end))
          (cons (foreign-ref 'unsigned-32 start 0)
                (foreign-ref 'unsigned-32 end 0)))
        (lambda ()
          (foreign-free start)
          (foreign-free end)))))

  (define (transaction-pending-edit-text value index)
    (require-open
      'transaction-pending-edit-text
      transaction?
      transaction-pointer
      value)
    (let ([size
            (%transaction-pending-edit-text-size
              (transaction-pointer value)
              index)])
      (when (= size text-npos)
        (native-error 'transaction-pending-edit-text))
      (let ([output (make-bytevector size)])
        (check-status
          'transaction-pending-edit-text
          (%transaction-copy-pending-edit-text
            (transaction-pointer value)
            index
            output
            size))
        output)))

  (define (transaction-snapshot value)
    (require-open 'transaction-snapshot transaction? transaction-pointer value)
    (%make-snapshot
      (check-pointer 'transaction-snapshot
                     (%transaction-snapshot (transaction-pointer value)))))

  (define (transaction-commit! value)
    (require-open 'transaction-commit! transaction? transaction-pointer value)
    (let ([pointer (%transaction-commit (transaction-pointer value))])
      (when (null-pointer? pointer)
        (native-error 'transaction-commit!))
      (%transaction-destroy (transaction-pointer value))
      (transaction-pointer-set! value #f)
      (%make-change pointer)))

  (define (transaction-abort! value)
    (require-open 'transaction-abort! transaction? transaction-pointer value)
    (check-status 'transaction-abort!
                  (%transaction-abort (transaction-pointer value)))
    (%transaction-destroy (transaction-pointer value))
    (transaction-pointer-set! value #f))

  (define (change-close! value)
    (when (and (change? value)
               (not (null-pointer? (change-pointer value))))
      (%change-destroy (change-pointer value))
      (change-pointer-set! value #f)))

  (define (change-old-revision value)
    (require-open 'change-old-revision change? change-pointer value)
    (check-revision
      'change-old-revision
      (%change-old-revision (change-pointer value))))

  (define (change-new-revision value)
    (require-open 'change-new-revision change? change-pointer value)
    (check-revision
      'change-new-revision
      (%change-new-revision (change-pointer value))))

  (define (change-edit-count value)
    (require-open 'change-edit-count change? change-pointer value)
    (%change-edit-count (change-pointer value)))

  (define (change-edit-range value index)
    (require-open 'change-edit-range change? change-pointer value)
    (let ([start (%change-edit-start (change-pointer value) index)])
      (when (= start text-npos)
        (native-error 'change-edit-range))
      (let ([end (%change-edit-end (change-pointer value) index)])
        (when (= end text-npos)
          (native-error 'change-edit-range))
        (cons start end))))

  (define (change-edit-text value index)
    (require-open 'change-edit-text change? change-pointer value)
    (let ([size (%change-edit-text-size (change-pointer value) index)])
      (when (= size text-npos)
        (native-error 'change-edit-text))
      (let ([output (make-bytevector size)])
        (check-status
          'change-edit-text
          (%change-copy-edit-text
            (change-pointer value)
            index
            output
            size))
        output)))

  (define (change-range who start-procedure end-procedure value)
    (require-open who change? change-pointer value)
    (let ([start (start-procedure (change-pointer value))])
      (when (= start text-npos)
        (native-error who))
      (let ([end (end-procedure (change-pointer value))])
        (when (= end text-npos)
          (native-error who))
        (cons start end))))

  (define (change-affected-old-range value)
    (change-range
      'change-affected-old-range
      %change-affected-old-start
      %change-affected-old-end
      value))

  (define (change-affected-new-range value)
    (change-range
      'change-affected-new-range
      %change-affected-new-start
      %change-affected-new-end
      value)))
