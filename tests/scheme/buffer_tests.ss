#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor language))

(define events '())

(define (record! event)
  (set! events (cons event events)))

(define provider
  (make-syntax-provider
    '(context pair)
    (lambda (snapshot)
      (record! (list 'open (snapshot-revision snapshot)))
      (vector (snapshot-revision snapshot)))
    (lambda (session change snapshot)
      (unless (= (vector-ref session 0) (change-old-revision change))
        (error 'buffer-tests "session revision was stale"))
      (vector-set! session 0 (snapshot-revision snapshot))
      (record! (list 'sync
                     (change-old-revision change)
                     (change-new-revision change))))
    (lambda (session snapshot pending-edits)
      (record! (list 'view
                     (snapshot-revision snapshot)
                     (vector-length pending-edits)))
      (vector (snapshot-revision snapshot) pending-edits))
    (lambda (view)
      (record! (list 'close-view (vector-ref view 0))))
    (lambda (session)
      (record! (list 'close (vector-ref session 0))))))

(register-language-profile!
  (make-language-profile 'test-language provider))

(register-major-mode!
  (make-major-mode
    'prog-mode
    'fundamental-mode
    'inherit
    'editing
    'prog-map
    '((indent-width . 2))))

(register-major-mode!
  (make-major-mode
    'test-mode
    'prog-mode
    'test-language
    'editing
    'test-map
    '((tab-width . 8))))

(define document (make-document "abc" 41))
(define buffer (make-buffer 7 document "test.cc" 'test-mode))

(unless (eq? (buffer-major-mode-name buffer) 'test-mode)
  (error 'buffer-tests "major mode differs"))
(unless (= (buffer-mode-generation buffer) 1)
  (error 'buffer-tests "initial mode generation differs"))
(unless (= (buffer-language-revision buffer) 0)
  (error 'buffer-tests "initial language revision differs"))
(unless (= (buffer-setting-ref buffer 'indent-width) 2)
  (error 'buffer-tests "parent setting was not inherited"))
(unless (= (buffer-setting-ref buffer 'tab-width) 8)
  (error 'buffer-tests "mode setting differs"))

(buffer-set-local-setting! buffer 'indent-width 6)
(unless (= (buffer-setting-ref buffer 'indent-width) 6)
  (error 'buffer-tests "local setting did not override mode setting"))
(buffer-clear-local-setting! buffer 'indent-width)
(unless (= (buffer-setting-ref buffer 'indent-width) 2)
  (error 'buffer-tests "cleared setting did not reveal mode default"))

(define command-result #f)
(define change #f)
(call-with-values
  (lambda ()
    (call-with-buffer-transaction
      buffer
      (lambda (transaction)
        (transaction-insert! transaction 3 "d")
        (call-with-buffer-syntax-view
          buffer
          transaction
          (lambda (view)
            (unless (= (vector-ref view 0) 1)
              (error 'buffer-tests "speculative view revision differs"))
            (let* ([pending-edits (vector-ref view 1)]
                   [edit (vector-ref pending-edits 0)])
              (unless (and (= (vector-length pending-edits) 1)
                           (= (vector-ref edit 0) 3)
                           (= (vector-ref edit 1) 3)
                           (bytevector=?
                             (vector-ref edit 2)
                             (string->utf8 "d")))
                (error 'buffer-tests "speculative pending edits differ")))
            'inserted)))))
  (lambda (result committed-change)
    (set! command-result result)
    (set! change committed-change)))

(unless (eq? command-result 'inserted)
  (error 'buffer-tests "command result differs"))
(unless (= (document-revision (buffer-document buffer)) 1)
  (error 'buffer-tests "document revision did not advance"))
(unless (= (buffer-language-revision buffer) 1)
  (error 'buffer-tests "language revision did not advance"))
(unless (not (buffer-language-error buffer))
  (error 'buffer-tests "language runtime reported an error"))

(define after (document-snapshot (buffer-document buffer)))
(define after-text (snapshot-text after))
(unless (bytevector=? (text->bytevector after-text) (string->utf8 "abcd"))
  (error 'buffer-tests "transaction text differs"))

(define undone (buffer-undo! buffer))
(unless undone
  (error 'buffer-tests "buffer undo returned no change"))
(unless (= (buffer-language-revision buffer) 2)
  (error 'buffer-tests "undo did not synchronize language runtime"))

(define redone (buffer-redo! buffer))
(unless redone
  (error 'buffer-tests "buffer redo returned no change"))
(unless (= (buffer-language-revision buffer) 3)
  (error 'buffer-tests "redo did not synchronize language runtime"))

(buffer-set-major-mode! buffer 'fundamental-mode)
(unless (not (buffer-language-profile buffer))
  (error 'buffer-tests "fundamental mode retained a language profile"))
(unless (= (buffer-mode-generation buffer) 2)
  (error 'buffer-tests "mode generation did not advance"))

(buffer-set-major-mode! buffer 'test-mode)
(unless (= (buffer-language-revision buffer)
           (document-revision (buffer-document buffer)))
  (error 'buffer-tests "reopened language runtime is stale"))

(define no-op-change #f)
(call-with-values
  (lambda ()
    (call-with-buffer-transaction buffer (lambda (transaction) 'no-op)))
  (lambda (result committed-change)
    (unless (eq? result 'no-op)
      (error 'buffer-tests "no-op command result differs"))
    (set! no-op-change committed-change)))

(unless (= (change-old-revision no-op-change)
           (change-new-revision no-op-change))
  (error 'buffer-tests "no-op transaction changed the revision"))

(define aborted?
  (guard (condition [else #t])
    (call-with-buffer-transaction
      buffer
      (lambda (transaction)
        (transaction-insert! transaction 0 "discarded")
        (error 'buffer-tests "abort transaction")))
    #f))

(unless aborted?
  (error 'buffer-tests "transaction exception was not propagated"))
(unless (= (document-revision (buffer-document buffer)) 3)
  (error 'buffer-tests "aborted transaction changed the document"))

(unless (equal? (reverse events)
                '((open 0)
                  (view 1 1)
                  (close-view 1)
                  (sync 0 1)
                  (sync 1 2)
                  (sync 2 3)
                  (close 3)
                  (open 3)))
  (error 'buffer-tests "unexpected provider lifecycle" (reverse events)))

(change-close! undone)
(change-close! redone)
(text-close! after-text)
(snapshot-close! after)
(change-close! change)
(change-close! no-op-change)
(buffer-close! buffer)

(unless (buffer-closed? buffer)
  (error 'buffer-tests "buffer did not close"))

(define failing-open-count 0)
(define failing-provider
  (make-syntax-provider
    '(context)
    (lambda (snapshot)
      (set! failing-open-count (+ failing-open-count 1))
      (vector (snapshot-revision snapshot)))
    (lambda (session change snapshot)
      (error 'failing-provider "sync failed"))
    (lambda (session) #f)))

(register-language-profile!
  (make-language-profile 'failing-language failing-provider))
(register-major-mode!
  (make-major-mode
    'failing-mode
    'prog-mode
    'failing-language
    'editing
    'failing-map
    '()))

(define failing-document (make-document "x" 42))
(define failing-buffer
  (make-buffer 8 failing-document "failing.cc" 'failing-mode))
(define failing-change #f)

(call-with-values
  (lambda ()
    (call-with-buffer-transaction
      failing-buffer
      (lambda (transaction)
        (transaction-insert! transaction 1 "y"))))
  (lambda (result committed-change)
    (set! failing-change committed-change)))

(unless (= (document-revision (buffer-document failing-buffer)) 1)
  (error 'buffer-tests "provider failure rolled back committed text"))
(unless (= (buffer-language-revision failing-buffer) 1)
  (error 'buffer-tests "provider failure did not rebuild the session"))
(unless (buffer-language-error failing-buffer)
  (error 'buffer-tests "provider failure was not retained"))
(unless (= failing-open-count 2)
  (error 'buffer-tests "provider session was not reopened"))

(change-close! failing-change)
(buffer-close! failing-buffer)

(define external-document (make-document "a" 43))
(define external-buffer
  (make-buffer
    9
    external-document
    "external.txt"
    'fundamental-mode))
(define external-transaction
  (document-begin-transaction external-document))
(transaction-insert! external-transaction 1 "b")
(define external-change
  (transaction-commit! external-transaction))
(transaction-close! external-transaction)

(define unadopted-change-rejected? #f)
(guard (condition
         [else (set! unadopted-change-rejected? #t)])
  (call-with-buffer-transaction
    external-buffer
    (lambda (transaction) 'unexpected)))
(unless unadopted-change-rejected?
  (error 'buffer-tests "buffer accepted an unadopted document change"))

(buffer-adopt-change! external-buffer external-change)
(unless (= (buffer-revision external-buffer)
           (document-revision external-document)
           1)
  (error 'buffer-tests "buffer did not adopt the document revision"))

(define duplicate-adoption-rejected? #f)
(guard (condition
         [else (set! duplicate-adoption-rejected? #t)])
  (buffer-adopt-change! external-buffer external-change))
(unless duplicate-adoption-rejected?
  (error 'buffer-tests "buffer adopted the same change twice"))

(define following-change #f)
(call-with-values
  (lambda ()
    (call-with-buffer-transaction
      external-buffer
      (lambda (transaction)
        (transaction-insert! transaction 2 "c"))))
  (lambda (result change)
    (set! following-change change)))
(unless (= (buffer-revision external-buffer) 2)
  (error 'buffer-tests "buffer transaction did not advance its revision"))

(change-close! following-change)
(change-close! external-change)
(buffer-close! external-buffer)
