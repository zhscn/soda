(library (soda core value)
  (export make-owner
          exact-integer?
          owner?
          owner-id
          owner-name
          owner-generation
          owner-active?
          owner-add-cleanup!
          owner-remove-cleanup!
          owner-next-generation!
          owner-close!
          owner-assert-active
          make-registration
          registration?
          registration-owner
          registration-active?
          registration-close!
          make-identity-source
          identity-source?
          identity-source-next!)
  (import (rnrs))

  (define (exact-integer? value)
    (and (integer? value) (exact? value)))

  ;; Identity is allocated by a source and is never recycled.  The source is
  ;; deliberately small so that each core service can own its namespace.
  (define-record-type
    (identity-source %make-identity-source identity-source?)
    (fields (mutable next identity-source-next identity-source-next-set!)))

  (define (make-identity-source)
    (%make-identity-source 0))

  (define (identity-source-next! source)
    (unless (identity-source? source)
      (assertion-violation
        'identity-source-next!
        "expected an identity source"
        source))
    (let ([value (identity-source-next source)])
      (identity-source-next-set! source (+ value 1))
      value))

  (define owner-source (make-identity-source))

  (define-record-type
    (owner %make-owner owner?)
    (fields
      (immutable id owner-id)
      (immutable name owner-name)
      (mutable generation owner-generation owner-generation-set!)
      (mutable active? owner-active? owner-active?-set!)
      (mutable cleanups owner-cleanups owner-cleanups-set!)))

  (define make-owner
    (case-lambda
      [() (make-owner 'anonymous)]
      [(name)
       (unless (symbol? name)
         (assertion-violation 'make-owner "name must be a symbol" name))
       (%make-owner
         (identity-source-next! owner-source)
         name
         0
         #t
         '())]))

  (define (owner-assert-active who owner)
    (unless (owner? owner)
      (assertion-violation who "expected an owner" owner))
    (unless (owner-active? owner)
      (assertion-violation who "owner is closed" owner))
    owner)

  (define (owner-next-generation! owner)
    (owner-assert-active 'owner-next-generation! owner)
    (let ([generation (+ (owner-generation owner) 1)])
      (owner-generation-set! owner generation)
      generation))

  (define (owner-add-cleanup! owner cleanup)
    (owner-assert-active 'owner-add-cleanup! owner)
    (unless (procedure? cleanup)
      (assertion-violation
        'owner-add-cleanup!
        "cleanup must be a procedure"
        cleanup))
    (owner-cleanups-set!
      owner
      (cons cleanup (owner-cleanups owner)))
    cleanup)

  (define (owner-remove-cleanup! owner cleanup)
    (unless (owner? owner)
      (assertion-violation
        'owner-remove-cleanup! "expected an owner" owner))
    (let ([before (owner-cleanups owner)])
      (owner-cleanups-set!
        owner
        (filter (lambda (candidate) (not (eq? candidate cleanup))) before))
      (not (= (length before) (length (owner-cleanups owner))))))

  (define (owner-close! owner)
    (unless (owner? owner)
      (assertion-violation 'owner-close! "expected an owner" owner))
    (if (not (owner-active? owner))
        #f
        (let ([failures '()])
          ;; Detach each cleanup batch before invoking it.  A cleanup may
          ;; register another owner-scoped resource; that resource is then
          ;; collected by the next batch instead of being silently lost.
          (let loop ()
            (let ([cleanups (owner-cleanups owner)])
              (owner-cleanups-set! owner '())
              (unless (null? cleanups)
                (for-each
                  (lambda (cleanup)
                    (guard
                      (condition
                        [else (set! failures (cons condition failures))])
                      (cleanup)))
                  cleanups)
                (loop))))
          (owner-active?-set! owner #f)
          (owner-generation-set! owner (+ (owner-generation owner) 1))
          (if (null? failures)
              #t
              (raise (car failures))))))

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
                   (owner-remove-cleanup! owner owner-cleanup)
                   (close))
                 #t)]
             [owner-cleanup
               (lambda () (registration-close! registration))])
      (owner-add-cleanup! owner owner-cleanup)
      registration))

  (define (registration-close! value)
    (unless (registration? value)
      (assertion-violation
        'registration-close! "expected a registration" value))
    (if (not (registration-active? value))
        #f
        (begin
          (registration-active?-set! value #f)
          ((registration-close-procedure value))
          #t)))
)
