#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor decoration)
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
    #f
    (lambda (session query-name start end)
      (list
        (make-syntax-capture
          (if (eq? query-name 'fold) 'fold.region 'query.capture)
          start
          end
          "test_node"
          '((role . block))
          0)))
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
    '((indent-width . 2))
    '((display-map-provider . parent-display))))

(register-major-mode!
  (make-major-mode
    'test-mode
    'prog-mode
    'test-language
    'inherit
    'test-map
    '((tab-width . 8))
    '((outline-provider . test-outline))))

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
(unless
  (and
    (eq?
      (resolve-major-mode-interaction-class 'test-mode)
      'editing)
    (eq?
      (major-mode-feature-ref
        'test-mode
        'display-map-provider
        #f)
      'parent-display)
    (eq?
      (major-mode-feature-ref
        'test-mode
        'outline-provider
        #f)
      'test-outline)
    (equal?
      (major-mode-syntax-capabilities 'test-mode)
      '(context pair)))
  (error 'buffer-tests
         "major mode features or syntax capabilities did not resolve"))
(let ([captures (syntax-query provider #f 'fold 1 3)])
  (unless
    (and
      (= (length captures) 1)
      (eq? (syntax-capture-name (car captures)) 'fold.region)
      (= (syntax-capture-start (car captures)) 1)
      (= (syntax-capture-end (car captures)) 3)
      (equal?
        (syntax-capture-properties (car captures))
        '((role . block))))
    (error 'buffer-tests "syntax capture query result differs")))

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
(unless (buffer-modified? buffer)
  (error 'buffer-tests "edit did not mark the buffer modified"))

(define after (document-snapshot (buffer-document buffer)))
(define after-text (snapshot-text after))
(unless (bytevector=? (text->bytevector after-text) (string->utf8 "abcd"))
  (error 'buffer-tests "transaction text differs"))

(define undone (buffer-undo! buffer))
(unless undone
  (error 'buffer-tests "buffer undo returned no change"))
(unless (= (buffer-language-revision buffer) 2)
  (error 'buffer-tests "undo did not synchronize language runtime"))
(unless (not (buffer-modified? buffer))
  (error 'buffer-tests
         "undo to the saved history node left the buffer modified"))

(define redone (buffer-redo! buffer))
(unless redone
  (error 'buffer-tests "buffer redo returned no change"))
(unless (= (buffer-language-revision buffer) 3)
  (error 'buffer-tests "redo did not synchronize language runtime"))
(unless (buffer-modified? buffer)
  (error 'buffer-tests "redo away from the saved history node was clean"))

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

(define highlight-build-count 0)
(define (counting-highlight-index snapshot)
  (set! highlight-build-count (+ highlight-build-count 1))
  (let ([text (snapshot-text snapshot)])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (make-decoration-index
          (if (positive? (text-size text))
              (list
                (make-decoration-run
                  0
                  (text-size text)
                  'syntax-test
                  'base-syntax
                  0
                  'test
                  (snapshot-revision snapshot)))
              '())))
      (lambda () (text-close! text)))))

(define counting-highlight-provider
  (make-syntax-provider
    '(highlight)
    (lambda (snapshot)
      (vector
        (snapshot-revision snapshot)
        (counting-highlight-index snapshot)))
    (lambda (session change snapshot)
      (vector-set! session 0 (snapshot-revision snapshot))
      (vector-set! session 1 (counting-highlight-index snapshot)))
    #f
    #f
    (lambda (session start end)
      (decoration-index-runs-in-range
        (vector-ref session 1)
        start
        end))
    (lambda (session) #f)))

(register-language-profile!
  (make-language-profile
    'highlight-test
    counting-highlight-provider))
(register-major-mode!
  (make-major-mode
    'highlight-test-mode
    'fundamental-mode
    'highlight-test
    'editing
    #f
    '()))

(define highlight-cache-document (make-document "abcdef" 44))
(define highlight-cache-buffer
  (make-buffer
    10
    highlight-cache-document
    "highlight-test"
    'highlight-test-mode))
(unless (= highlight-build-count 1)
  (error 'buffer-tests "initial highlight snapshot was not built once"))
(unless
  (and
    (= (length (buffer-highlight-runs highlight-cache-buffer 0 1)) 1)
    (= (length (buffer-highlight-runs highlight-cache-buffer 4 6)) 1)
    (= highlight-build-count 1))
  (error 'buffer-tests "highlight range query rebuilt the snapshot"))

(define highlight-cache-change #f)
(call-with-values
  (lambda ()
    (call-with-buffer-transaction
      highlight-cache-buffer
      (lambda (transaction)
        (transaction-insert! transaction 6 "!"))))
  (lambda (result committed-change)
    (set! highlight-cache-change committed-change)))
(unless
  (and
    (= highlight-build-count 2)
    (= (length
         (buffer-highlight-runs highlight-cache-buffer 6 7))
       1))
  (error 'buffer-tests "highlight snapshot did not follow revision"))

(buffer-set-local! highlight-cache-buffer 'result-owner 'xref)
(unless (eq? (buffer-local-ref highlight-cache-buffer 'result-owner) 'xref)
  (error 'buffer-tests "buffer-local data was not retained"))
(buffer-clear-local! highlight-cache-buffer 'result-owner)
(unless (eq? (buffer-local-ref highlight-cache-buffer 'result-owner 'missing)
             'missing)
  (error 'buffer-tests "buffer-local data was not cleared"))

(buffer-add-text-properties!
  highlight-cache-buffer
  1
  4
  '((location . target) (face . search-match)))
(unless
  (and
    (eq? (buffer-text-property-ref
           highlight-cache-buffer 2 'location)
         'target)
    (not (buffer-text-property-ref
           highlight-cache-buffer 4 'location #f))
    (= (buffer-next-text-property-change highlight-cache-buffer 0 7) 1)
    (= (buffer-next-text-property-change highlight-cache-buffer 1 7) 4)
    (= (buffer-previous-text-property-change highlight-cache-buffer 7 0) 4)
    (equal?
      (map decoration-run-face
        (buffer-text-property-decoration-runs
          highlight-cache-buffer 0 7))
      '(search-match)))
  (error 'buffer-tests "text property lookup or decoration projection failed"))

(define property-anchor-change #f)
(call-with-values
  (lambda ()
    (call-with-buffer-transaction
      highlight-cache-buffer
      (lambda (transaction)
        (transaction-insert! transaction 0 "x"))))
  (lambda (result committed-change)
    (set! property-anchor-change committed-change)))
(unless
  (and
    (not (buffer-text-property-ref
           highlight-cache-buffer 1 'location #f))
    (eq? (buffer-text-property-ref
           highlight-cache-buffer 2 'location)
         'target))
  (error 'buffer-tests "text properties did not follow Document edits"))
(change-close! property-anchor-change)
(buffer-clear-text-properties! highlight-cache-buffer)
(unless
  (null? (buffer-text-properties-at highlight-cache-buffer 2))
  (error 'buffer-tests "text properties were not cleared"))

(let* ([low
         (make-decoration-run
           0 8 'low 'base-syntax 0 'test 'low)]
       [high
         (make-decoration-run
           2 4 'high 'diagnostic 10 'test 'high)]
       [index (make-decoration-index (list high low))]
       [chunks
         (decoration-runs->styled-chunks
           (decoration-index-runs-in-range index 0 8)
           0
           8)]
       [sweep
         (make-decoration-sweep
           (decoration-index-runs-in-range index 1 6)
           1)])
  (unless
    (and
      (equal?
        (map decoration-run-face
             (decoration-sweep-runs-at! sweep 1))
        '(low))
      (equal?
        (map decoration-run-face
             (decoration-sweep-runs-at! sweep 2))
        '(low high))
      (equal?
        (map decoration-run-face
             (decoration-sweep-runs-at! sweep 4))
        '(low))
      (equal?
        (map
          (lambda (chunk)
            (list
              (styled-chunk-start chunk)
              (styled-chunk-end chunk)
              (map decoration-run-face
                   (styled-chunk-runs chunk))))
          chunks)
        '((0 2 (low))
          (2 4 (low high))
          (4 8 (low)))))
    (error 'buffer-tests "decoration index and sweep order differ")))

(change-close! highlight-cache-change)
(buffer-close! highlight-cache-buffer)
