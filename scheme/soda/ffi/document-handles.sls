(library (soda ffi document-handles)
  (export text?
          %make-text
          text-pointer
          text-pointer-set!
          document?
          %make-document
          document-pointer
          document-pointer-set!
          snapshot?
          %make-snapshot
          snapshot-pointer
          snapshot-pointer-set!
          transaction?
          %make-transaction
          transaction-pointer
          transaction-pointer-set!
          change?
          %make-change
          change-pointer
          change-pointer-set!)
  (import (chezscheme))

  (define-record-type (text %make-text text?)
    (fields (mutable pointer)))
  (define-record-type (document %make-document document?)
    (fields (mutable pointer)))
  (define-record-type (snapshot %make-snapshot snapshot?)
    (fields (mutable pointer)))
  (define-record-type (transaction %make-transaction transaction?)
    (fields (mutable pointer)))
  (define-record-type (change %make-change change?)
    (fields (mutable pointer))))
