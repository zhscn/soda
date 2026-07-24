#!r6rs
(import (rnrs)
        (soda document))

(define document (make-document "a\r\nb" 9))
(define before (document-snapshot document))
(define transaction (document-begin-transaction document))

(transaction-replace! transaction 2 3 "c")

(define speculative (transaction-snapshot transaction))
(define speculative-text (snapshot-text speculative))

(unless (bytevector=? (text->bytevector speculative-text) (string->utf8 "a\nc"))
  (error 'document-tests "speculative text differs"))

(define change (transaction-commit! transaction))

(unless (= (document-revision document) 1)
  (error 'document-tests "revision did not advance"))
(unless (= (change-edit-count change) 1)
  (error 'document-tests "expected one normalized edit"))
(unless (equal? (change-edit-range change 0) '(2 . 3))
  (error 'document-tests "unexpected edit range"))
(unless (bytevector=? (change-edit-text change 0) (string->utf8 "c"))
  (error 'document-tests "unexpected replacement"))

(define before-text (snapshot-text before))
(unless (bytevector=? (text->bytevector before-text) (string->utf8 "a\nb"))
  (error 'document-tests "persistent snapshot changed"))

(define undone (document-undo! document))
(unless undone
  (error 'document-tests "undo returned no change"))
(unless (document-can-redo? document)
  (error 'document-tests "redo is unavailable"))

(change-close! undone)
(text-close! before-text)
(change-close! change)
(text-close! speculative-text)
(snapshot-close! speculative)
(snapshot-close! before)
(document-close! document)
