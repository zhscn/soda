(library (soda kernel document)
  (export make-document
          document?
          document-id
          document-revision
          document-byte-size
          document-snapshot
          document-close!
          snapshot?
          snapshot-revision
          snapshot-byte-size
          snapshot-bytevector
          snapshot-subbytevector
          snapshot-string
          snapshot-close!
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
          change-old-revision
          change-new-revision
          change-edit-count
          change-edit-range
          change-edit-text
          change-affected-old-range
          change-affected-new-range
          change-close!)
  (import (rnrs)
          (rename (soda document)
                  (make-document native-make-document)
                  (document? native-document?)
                  (document-id native-document-id)
                  (document-revision native-document-revision)
                  (document-byte-size native-document-byte-size)
                  (document-snapshot native-document-snapshot)
                  (document-close! native-document-close!)
                  (snapshot-revision native-snapshot-revision)
                  (snapshot-byte-size native-snapshot-byte-size)
                  (snapshot? native-snapshot?)
                  (snapshot-text native-snapshot-text)
                  (snapshot-close! native-snapshot-close!)
                  (text->bytevector native-text->bytevector)
                  (text-subbytevector native-text-subbytevector)
                  (text-close! native-text-close!)
                  (document-begin-transaction native-document-begin-transaction)
                  (transaction-base-revision native-transaction-base-revision)
                  (transaction? native-transaction?)
                  (transaction-insert! native-transaction-insert!)
                  (transaction-replace! native-transaction-replace!)
                  (transaction-erase! native-transaction-erase!)
                  (transaction-snapshot native-transaction-snapshot)
                  (transaction-commit! native-transaction-commit!)
                  (transaction-abort! native-transaction-abort!)
                  (change-old-revision native-change-old-revision)
                  (change? native-change?)
                  (change-new-revision native-change-new-revision)
                  (change-edit-count native-change-edit-count)
                  (change-edit-range native-change-edit-range)
                  (change-edit-text native-change-edit-text)
                  (change-affected-old-range native-change-affected-old-range)
                  (change-affected-new-range native-change-affected-new-range)
                  (change-close! native-change-close!)))

  (define-record-type
    (document %make-document document?)
    (fields (mutable native document-native document-native-set!)))

  (define-record-type
    (snapshot %make-snapshot snapshot?)
    (fields (mutable native snapshot-native snapshot-native-set!)))

  (define-record-type
    (document-transaction %make-document-transaction document-transaction?)
    (fields (mutable native document-transaction-native document-transaction-native-set!)))

  (define-record-type
    (change %make-change change?)
    (fields (mutable native change-native change-native-set!)))

  (define (open-native who value)
    (cond
      [(and (document? value) (document-native value)) (document-native value)]
      [(and (snapshot? value) (snapshot-native value)) (snapshot-native value)]
      [(and (document-transaction? value) (document-transaction-native value))
       (document-transaction-native value)]
      [(and (change? value) (change-native value)) (change-native value)]
      [else (assertion-violation who "object is closed or has an invalid type" value)]))

  (define (make-document data . id)
    (unless (or (string? data) (bytevector? data))
      (assertion-violation 'make-document "data must be a string or bytevector" data))
    (%make-document
      (native-make-document data (if (null? id) 0 (car id)))))

  (define (document-id value) (native-document-id (open-native 'document-id value)))
  (define (document-revision value)
    (native-document-revision (open-native 'document-revision value)))
  (define (document-byte-size value)
    (native-document-byte-size (open-native 'document-byte-size value)))

  (define (document-snapshot value)
    (%make-snapshot (native-document-snapshot (open-native 'document-snapshot value))))

  (define (snapshot-revision value)
    (native-snapshot-revision (open-native 'snapshot-revision value)))

  (define (snapshot-byte-size value)
    (native-snapshot-byte-size (open-native 'snapshot-byte-size value)))

  (define (snapshot-bytevector value)
    (let ([text (native-snapshot-text (open-native 'snapshot-bytevector value))])
      (dynamic-wind
        (lambda () #f)
        (lambda () (native-text->bytevector text))
        (lambda () (native-text-close! text)))))

  (define (snapshot-subbytevector value from to)
    (let ([text (native-snapshot-text (open-native 'snapshot-subbytevector value))])
      (dynamic-wind
        (lambda () #f)
        (lambda () (native-text-subbytevector text from to))
        (lambda () (native-text-close! text)))))

  (define (snapshot-string value)
    (utf8->string (snapshot-bytevector value)))

  (define (snapshot-close! value)
    (unless (snapshot? value)
      (assertion-violation 'snapshot-close! "expected a snapshot" value))
    (if (not (snapshot-native value))
        #f
        (begin
          (native-snapshot-close! (snapshot-native value))
          (snapshot-native-set! value #f)
          #t)))

  (define (document-close! value)
    (unless (document? value)
      (assertion-violation 'document-close! "expected a document" value))
    (if (not (document-native value))
        #f
        (begin
          (native-document-close! (document-native value))
          (document-native-set! value #f)
          #t)))

  (define (make-document-transaction value)
    (%make-document-transaction
      (native-document-begin-transaction (open-native 'make-document-transaction value))))

  (define (document-transaction-base-revision value)
    (native-transaction-base-revision (open-native 'document-transaction-base-revision value)))
  (define (document-transaction-insert! value offset text)
    (native-transaction-insert!
      (open-native 'document-transaction-insert! value) offset text))
  (define (document-transaction-replace! value from to text)
    (native-transaction-replace!
      (open-native 'document-transaction-replace! value) from to text))
  (define (document-transaction-erase! value from to)
    (native-transaction-erase!
      (open-native 'document-transaction-erase! value) from to))
  (define (document-transaction-snapshot value)
    (%make-snapshot
      (native-transaction-snapshot (open-native 'document-transaction-snapshot value))))

  (define (document-transaction-commit! value)
    (let ([native (open-native 'document-transaction-commit! value)])
      (document-transaction-native-set! value #f)
      (%make-change (native-transaction-commit! native))))

  (define (document-transaction-abort! value)
    (native-transaction-abort! (open-native 'document-transaction-abort! value))
    (document-transaction-native-set! value #f)
    #t)

  (define (change-old-revision value)
    (native-change-old-revision (open-native 'change-old-revision value)))
  (define (change-new-revision value)
    (native-change-new-revision (open-native 'change-new-revision value)))
  (define (change-edit-count value)
    (native-change-edit-count (open-native 'change-edit-count value)))
  (define (change-edit-range value index)
    (native-change-edit-range (open-native 'change-edit-range value) index))
  (define (change-edit-text value index)
    (native-change-edit-text (open-native 'change-edit-text value) index))
  (define (change-affected-old-range value)
    (native-change-affected-old-range (open-native 'change-affected-old-range value)))
  (define (change-affected-new-range value)
    (native-change-affected-new-range (open-native 'change-affected-new-range value)))
  (define (change-close! value)
    (unless (change? value)
      (assertion-violation 'change-close! "expected a change" value))
    (if (not (change-native value))
        #f
        (begin
          (native-change-close! (change-native value))
          (change-native-set! value #f)
          #t)))
)
