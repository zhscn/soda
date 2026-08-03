(library (soda host value)
  (export make-owner
          list-copy
          owner?
          owner-id
          owner-name
          owner-generation
          owner-active?
          owner-add-cleanup!
          owner-next-generation!
          owner-close!
          owner-assert-active
          make-registration
          registration?
          registration-active?
          registration-close!)
  (import (rnrs)
          (soda kernel value))

  (define owner-source (make-identity-source))

  (define-record-type
    (owner %make-owner owner?)
    (fields
      (immutable id owner-id)
      (immutable name owner-name)
      (mutable generation owner-generation owner-generation-set!)
      (mutable active? owner-active? owner-active?-set!)
      (mutable cleanups owner-cleanups owner-cleanups-set!)))

  (define (make-owner . name)
    (let ([value (if (null? name) 'anonymous (car name))])
      (unless (symbol? value)
        (assertion-violation 'make-owner "name must be a symbol" value))
      (%make-owner
        (identity-source-next! owner-source) value 0 #t '())))

  (define (owner-assert-active who value)
    (unless (owner? value)
      (assertion-violation who "expected an owner" value))
    (unless (owner-active? value)
      (assertion-violation who "owner is closed" value))
    value)

  (define (owner-add-cleanup! owner cleanup)
    (owner-assert-active 'owner-add-cleanup! owner)
    (unless (procedure? cleanup)
      (assertion-violation 'owner-add-cleanup! "cleanup must be a procedure" cleanup))
    (owner-cleanups-set! owner (cons cleanup (owner-cleanups owner)))
    cleanup)

  (define (owner-next-generation! owner)
    (owner-assert-active 'owner-next-generation! owner)
    (let ([generation (+ 1 (owner-generation owner))])
      (owner-generation-set! owner generation)
      generation))

  (define (owner-close! owner)
    (owner-assert-active 'owner-close! owner)
    (let ([cleanups (owner-cleanups owner)])
      (owner-cleanups-set! owner '())
      (for-each
        (lambda (cleanup)
          (guard (condition [else #f]) (cleanup)))
        cleanups)
      (owner-active?-set! owner #f)
      (owner-generation-set! owner (+ 1 (owner-generation owner)))
      #t))

  (define-record-type
    (registration %make-registration registration?)
    (fields
      (immutable owner registration-owner)
      (immutable close registration-close-procedure)
      (mutable active? registration-active? registration-active?-set!)))

  (define (make-registration owner close)
    (owner-assert-active 'make-registration owner)
    (unless (procedure? close)
      (assertion-violation 'make-registration "close must be a procedure" close))
    (letrec ([registration
               (%make-registration
                 owner
                 (lambda ()
                   (owner-cleanup-remove! owner cleanup)
                   (close))
                 #t)]
             [cleanup (lambda () (registration-close! registration))])
      (owner-add-cleanup! owner cleanup)
      registration))

  (define (owner-cleanup-remove! owner cleanup)
    (let loop ([items (owner-cleanups owner)] [result '()])
      (cond
        [(null? items) (owner-cleanups-set! owner (reverse result))]
        [(eq? cleanup (car items))
         (owner-cleanups-set! owner (append (reverse result) (cdr items)))]
        [else (loop (cdr items) (cons (car items) result))])))

  (define (registration-close! value)
    (unless (registration? value)
      (assertion-violation 'registration-close! "expected a registration" value))
    (if (not (registration-active? value))
        #f
        (begin
          (registration-active?-set! value #f)
          ((registration-close-procedure value))
          #t)))
)
