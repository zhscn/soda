(library (soda host runtime)
  (export make-runtime
          runtime?
          runtime-enqueue!
          runtime-enqueue-priority!
          make-runtime-request
          runtime-request?
          runtime-request-id
          runtime-request-owner
          runtime-request-scope
          runtime-request-generation
          runtime-request-payload
          runtime-request-status
          runtime-request-cancel!
          runtime-request-live?
          runtime-enqueue-request!
          runtime-pending?
          runtime-discard!
          runtime-drain!
          runtime-close!)
  (import (rnrs)
          (soda kernel value)
          (soda host value))

  (define-record-type
    (runtime %make-runtime runtime?)
    (fields
      (mutable front runtime-front runtime-front-set!)
      (mutable back runtime-back runtime-back-set!)
      (mutable next-id runtime-next-id runtime-next-id-set!)
      (mutable closed? runtime-closed? runtime-closed?-set!)))

  (define (make-runtime)
    (%make-runtime '() '() 0 #f))

  (define-record-type
    (runtime-request %make-runtime-request runtime-request?)
    (fields
      (immutable id runtime-request-id)
      (immutable owner runtime-request-owner)
      (immutable scope runtime-request-scope)
      (immutable generation runtime-request-generation)
      (immutable payload runtime-request-payload)
      (mutable status runtime-request-status runtime-request-status-set!)))

  (define (make-runtime-request id owner scope generation payload)
    (unless (and (exact-integer? id) (>= id 0))
      (assertion-violation 'make-runtime-request "invalid request id" id))
    (%make-runtime-request id owner scope generation payload 'pending))

  (define (runtime-request-live? request)
    (and (runtime-request? request)
         (eq? (runtime-request-status request) 'pending)))

  (define (runtime-request-cancel! request)
    (unless (runtime-request? request)
      (assertion-violation 'runtime-request-cancel! "expected a runtime request" request))
    (if (runtime-request-live? request)
        (begin (runtime-request-status-set! request 'cancelled) #t)
        #f))

  (define (runtime-enqueue-item! runtime item)
    (runtime-back-set! runtime (cons item (runtime-back runtime)))
    item)

  (define (runtime-enqueue! runtime message)
    (unless (and (runtime? runtime) (not (runtime-closed? runtime)))
      (assertion-violation 'runtime-enqueue! "runtime is closed" runtime))
    (runtime-enqueue-item! runtime message))

  ;; Priority messages run after the message currently being handled and
  ;; before older queued input.  Command messages use this path so an input
  ;; event observes the editor state published by the preceding event instead
  ;; of snapshotting a whole terminal-input burst before any command runs.
  (define (runtime-enqueue-priority! runtime message)
    (unless (and (runtime? runtime) (not (runtime-closed? runtime)))
      (assertion-violation 'runtime-enqueue-priority! "runtime is closed" runtime))
    (runtime-front-set! runtime (cons message (runtime-front runtime)))
    message)

  (define (runtime-enqueue-request! runtime owner scope generation payload)
    (unless (and (runtime? runtime) (not (runtime-closed? runtime)))
      (assertion-violation 'runtime-enqueue-request! "runtime is closed" runtime))
    (let* ([id (+ 1 (runtime-next-id runtime))]
           [request (make-runtime-request id owner scope generation payload)])
      (runtime-next-id-set! runtime id)
      (runtime-enqueue-item! runtime request)
      request))

  (define (runtime-pending? runtime)
    (unless (runtime? runtime)
      (assertion-violation 'runtime-pending? "expected a runtime" runtime))
    (or (pair? (runtime-front runtime)) (pair? (runtime-back runtime))))

  (define (runtime-discard! runtime predicate)
    (unless (and (runtime? runtime) (procedure? predicate))
      (assertion-violation 'runtime-discard!
                           "expected a runtime and predicate" runtime predicate))
    (let* ([old-front (runtime-front runtime)]
           [old-back (runtime-back runtime)]
           [new-front (filter (lambda (item) (not (predicate item))) old-front)]
           [new-back (filter (lambda (item) (not (predicate item))) old-back)])
      (runtime-front-set! runtime new-front)
      (runtime-back-set! runtime new-back)
      (- (+ (length old-front) (length old-back))
         (+ (length new-front) (length new-back)))))

  (define (runtime-next-item! runtime)
    (when (null? (runtime-front runtime))
      (runtime-front-set! runtime (reverse (runtime-back runtime)))
      (runtime-back-set! runtime '()))
    (if (null? (runtime-front runtime))
        #f
        (let ([item (car (runtime-front runtime))])
          (runtime-front-set! runtime (cdr (runtime-front runtime)))
          item)))

  (define (runtime-drain! runtime handler . limit)
    (unless (procedure? handler)
      (assertion-violation 'runtime-drain! "handler must be a procedure" handler))
    (let loop ([count 0]
               [maximum (if (null? limit) #f (car limit))])
      (if (or (and maximum (>= count maximum))
              (and (null? (runtime-front runtime)) (null? (runtime-back runtime))))
          count
          (let ([item (runtime-next-item! runtime)])
            (cond
              [(not item) count]
              [(and (runtime-request? item) (not (runtime-request-live? item)))
               (loop count maximum)]
              [else
               (handler item)
               (when (runtime-request? item)
                 (runtime-request-status-set! item 'completed))
               (loop (+ count 1) maximum)])))))

  (define (runtime-close! runtime)
    (unless (runtime? runtime)
      (assertion-violation 'runtime-close! "expected a runtime" runtime))
    (runtime-front-set! runtime '())
    (runtime-back-set! runtime '())
    (runtime-closed?-set! runtime #t)
    #t)
)
