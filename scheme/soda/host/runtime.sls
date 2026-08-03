(library (soda host runtime)
  (export make-runtime
          runtime?
          runtime-enqueue!
          runtime-drain!
          runtime-close!)
  (import (rnrs)
          (soda host value))

  (define-record-type
    (runtime %make-runtime runtime?)
    (fields
      (mutable queue runtime-queue runtime-queue-set!)
      (mutable closed? runtime-closed? runtime-closed?-set!)))

  (define (make-runtime)
    (%make-runtime '() #f))

  (define (runtime-enqueue! runtime message)
    (unless (and (runtime? runtime) (not (runtime-closed? runtime)))
      (assertion-violation 'runtime-enqueue! "runtime is closed" runtime))
    (runtime-queue-set! runtime
                        (append (runtime-queue runtime) (list message)))
    message)

  (define (runtime-drain! runtime handler . limit)
    (unless (procedure? handler)
      (assertion-violation 'runtime-drain! "handler must be a procedure" handler))
    (let loop ([items (runtime-queue runtime)]
               [count 0]
               [maximum (if (null? limit) #f (car limit))])
      (if (or (null? items) (and maximum (>= count maximum)))
          (begin (runtime-queue-set! runtime items) count)
          (begin (handler (car items))
                 (loop (cdr items) (+ count 1) maximum)))))

  (define (runtime-close! runtime)
    (unless (runtime? runtime)
      (assertion-violation 'runtime-close! "expected a runtime" runtime))
    (runtime-queue-set! runtime '())
    (runtime-closed?-set! runtime #t)
    #t)
)
