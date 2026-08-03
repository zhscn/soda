(library (soda core document)
  (export make-core-document
          core-document?
          core-document-native
          core-document-id
          core-document-revision
          core-document-byte-size
          core-document-close!
          core-document-snapshot
          core-snapshot?
          core-snapshot-revision
          core-snapshot-byte-size
          core-snapshot-close!
          core-document-begin-transaction
          core-transaction?
          core-transaction-insert!
          core-transaction-replace!
          core-transaction-erase!
          core-transaction-base-revision
          core-transaction-snapshot
          core-transaction-commit!
          core-transaction-abort!
          core-document-can-undo?
          core-document-can-redo?
          core-document-undo!
          core-document-redo!
          core-document-undo-to!
          core-change?
          core-change-old-revision
          core-change-new-revision
          core-change-close!
          core-document-create-anchor!
          core-document-remove-anchor!
          core-document-anchor-offset
          core-document-anchor-affinity
          core-document-set-anchor-affinity!
          core-document-editable-start
          core-document-set-editable-start!
          core-anchor-before-insertion
          core-anchor-after-insertion)
  (import (rnrs)
          (soda document))

  (define core-anchor-before-insertion 0)
  (define core-anchor-after-insertion 1)

  (define-record-type
    (core-document %make-core-document core-document?)
    (fields (mutable native core-document-native core-document-native-set!)))

  (define-record-type
    (core-snapshot %make-core-snapshot core-snapshot?)
    (fields (mutable native core-snapshot-native core-snapshot-native-set!)))

  (define-record-type
    (core-transaction %make-core-transaction core-transaction?)
    (fields
      (mutable native core-transaction-native core-transaction-native-set!)))

  (define-record-type
    (core-change %make-core-change core-change?)
    (fields (mutable native core-change-native core-change-native-set!)))

  (define (require-open who value)
    (unless (core-document? value)
      (assertion-violation who "expected a core document" value))
    (unless (core-document-native value)
      (assertion-violation who "document is closed" value))
    (core-document-native value))

  (define make-core-document
    (case-lambda
      [(data) (make-core-document data 0)]
      [(data id)
       (unless (or (string? data) (bytevector? data))
         (assertion-violation
           'make-core-document
           "data must be a string or bytevector"
           data))
       (%make-core-document (make-document data id))]))

  (define (core-document-id value)
    (document-id (require-open 'core-document-id value)))

  (define (core-document-revision value)
    (document-revision (require-open 'core-document-revision value)))

  (define (core-document-byte-size value)
    (document-byte-size (require-open 'core-document-byte-size value)))

  (define (core-document-close! value)
    (let ([native (require-open 'core-document-close! value)])
      (document-close! native)
      (core-document-native-set! value #f)
      #t))

  (define (core-document-snapshot value)
    (%make-core-snapshot
      (document-snapshot (require-open 'core-document-snapshot value))))

  (define (require-open-snapshot who value)
    (unless (core-snapshot? value)
      (assertion-violation who "expected a core snapshot" value))
    (unless (core-snapshot-native value)
      (assertion-violation who "snapshot is closed" value))
    (core-snapshot-native value))

  (define (core-snapshot-revision value)
    (snapshot-revision (require-open-snapshot 'core-snapshot-revision value)))

  (define (core-snapshot-byte-size value)
    (snapshot-byte-size (require-open-snapshot 'core-snapshot-byte-size value)))

  (define (core-snapshot-close! value)
    (let ([native (require-open-snapshot 'core-snapshot-close! value)])
      (snapshot-close! native)
      (core-snapshot-native-set! value #f)
      #t))

  (define (core-document-begin-transaction value)
    (%make-core-transaction
      (document-begin-transaction
        (require-open 'core-document-begin-transaction value))))

  (define (require-open-transaction who value)
    (unless (core-transaction? value)
      (assertion-violation who "expected a core transaction" value))
    (unless (core-transaction-native value)
      (assertion-violation who "transaction is closed" value))
    (core-transaction-native value))

  (define (core-transaction-insert! value offset inserted)
    (transaction-insert!
      (require-open-transaction 'core-transaction-insert! value)
      offset
      inserted))

  (define (core-transaction-replace! value start end replacement)
    (transaction-replace!
      (require-open-transaction 'core-transaction-replace! value)
      start
      end
      replacement))

  (define (core-transaction-erase! value start end)
    (transaction-erase!
      (require-open-transaction 'core-transaction-erase! value)
      start
      end))

  (define (core-transaction-base-revision value)
    (transaction-base-revision
      (require-open-transaction 'core-transaction-base-revision value)))

  (define (core-transaction-snapshot value)
    (%make-core-snapshot
      (transaction-snapshot
        (require-open-transaction 'core-transaction-snapshot value))))

  (define (core-transaction-commit! value)
    (let* ([native (require-open-transaction 'core-transaction-commit! value)]
           [change (transaction-commit! native)])
      (core-transaction-native-set! value #f)
      (%make-core-change change)))

  (define (core-transaction-abort! value)
    (let ([native (require-open-transaction 'core-transaction-abort! value)])
      (transaction-abort! native)
      (core-transaction-native-set! value #f)
      #t))

  (define (require-open-change who value)
    (unless (core-change? value)
      (assertion-violation who "expected a core change" value))
    (unless (core-change-native value)
      (assertion-violation who "change is closed" value))
    (core-change-native value))

  (define (core-change-old-revision value)
    (change-old-revision (require-open-change 'core-change-old-revision value)))

  (define (core-change-new-revision value)
    (change-new-revision (require-open-change 'core-change-new-revision value)))

  (define (core-change-close! value)
    (let ([native (require-open-change 'core-change-close! value)])
      (change-close! native)
      (core-change-native-set! value #f)
      #t))

  (define (core-document-can-undo? value)
    (document-can-undo? (require-open 'core-document-can-undo? value)))

  (define (core-document-can-redo? value)
    (document-can-redo? (require-open 'core-document-can-redo? value)))

  (define (core-document-undo! value)
    (%make-core-change
      (document-undo! (require-open 'core-document-undo! value))))

  (define (core-document-redo! value)
    (%make-core-change
      (document-redo! (require-open 'core-document-redo! value))))

  (define (core-document-undo-to! value node)
    (%make-core-change
      (document-undo-to! (require-open 'core-document-undo-to! value) node)))

  (define (core-document-create-anchor! value offset affinity)
    (document-create-anchor!
      (require-open 'core-document-create-anchor! value)
      offset
      affinity))

  (define (core-document-remove-anchor! value anchor)
    (document-remove-anchor!
      (require-open 'core-document-remove-anchor! value)
      anchor))

  (define (core-document-anchor-offset value anchor)
    (document-anchor-offset
      (require-open 'core-document-anchor-offset value)
      anchor))

  (define (core-document-anchor-affinity value anchor)
    (document-anchor-affinity
      (require-open 'core-document-anchor-affinity value)
      anchor))

  (define (core-document-set-anchor-affinity! value anchor affinity)
    (document-set-anchor-affinity!
      (require-open 'core-document-set-anchor-affinity! value)
      anchor
      affinity))

  (define (core-document-editable-start value)
    (document-editable-start
      (require-open 'core-document-editable-start value)))

  (define (core-document-set-editable-start! value offset)
    (document-set-editable-start!
      (require-open 'core-document-set-editable-start! value)
      offset))
)
