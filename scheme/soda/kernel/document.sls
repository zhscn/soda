(library (soda kernel document)
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
          snapshot-bytevector
          snapshot-subbytevector
          snapshot-string
          make-document-transaction
          document-transaction?
          document-transaction-base-revision
          document-transaction-insert!
          document-transaction-replace!
          document-transaction-erase!
          document-transaction-snapshot
          document-transaction-commit!
          document-transaction-abort!
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
          (soda ffi helpers)
          (soda ffi document)
          (soda ffi document-handles))

  (define (check-pointer who pointer)
    (when (native-null-pointer? pointer)
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
    (when (native-null-pointer? (pointer value))
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
               (not (native-null-pointer? (text-pointer value))))
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
               (not (native-null-pointer? (document-pointer value))))
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
    (if (native-null-pointer? pointer)
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
               (not (native-null-pointer? (snapshot-pointer value))))
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

  (define (snapshot-bytevector snapshot)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda () (text->bytevector text))
        (lambda () (text-close! text)))))

  (define (snapshot-subbytevector snapshot from to)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda () (text-subbytevector text from to))
        (lambda () (text-close! text)))))

  (define (snapshot-string snapshot)
    (utf8->string (snapshot-bytevector snapshot)))

  (define (transaction-close! value)
    (when (and (transaction? value)
               (not (native-null-pointer? (transaction-pointer value))))
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
      (when (native-null-pointer? pointer)
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
               (not (native-null-pointer? (change-pointer value))))
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
      value))

  ;; The kernel names transactions explicitly.  The underlying native ABI
  ;; uses the shorter transaction names; these aliases keep one handle model
  ;; and avoid a second wrapper record layer.
  (define make-document-transaction document-begin-transaction)
  (define document-transaction? transaction?)
  (define document-transaction-base-revision transaction-base-revision)
  (define document-transaction-insert! transaction-insert!)
  (define document-transaction-replace! transaction-replace!)
  (define document-transaction-erase! transaction-erase!)
  (define document-transaction-snapshot transaction-snapshot)
  (define document-transaction-commit! transaction-commit!)
  (define document-transaction-abort! transaction-abort!)
)
