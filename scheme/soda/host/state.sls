(library (soda host state)
  (export make-host-state
          host-state?
          host-state-owner
          host-state-runtime
          host-state-buffers
          host-state-views
          host-state-commands
          host-state-conditions
          host-state-display
          host-state-dispatch
          host-state-packages
          host-state-configuration
          host-state-closed?
          host-state-run!
          host-state-close!)
  (import (rnrs)
          (soda host buffer)
          (soda host command)
          (soda host condition)
          (soda host dispatch)
          (soda host display)
          (soda host runtime)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda kernel extension)
          (soda kernel value))

  (define-record-type
    (host-state %make-host-state host-state?)
    (fields
      (immutable owner host-state-owner)
      (immutable runtime host-state-runtime)
      (immutable buffers host-state-buffers)
      (immutable views host-state-views)
      (immutable commands host-state-commands)
      (immutable conditions host-state-conditions)
      (immutable display host-state-display)
      (immutable dispatch host-state-dispatch)
      (immutable packages host-state-packages)
      (immutable configuration host-state-configuration)
      (mutable closed? host-state-closed? host-state-closed?-set!)))

  (define (make-host-state)
    (let* ([owner (make-owner 'host)]
           [runtime (make-runtime)]
           [buffers (make-buffer-service)]
           [views (make-view-service)]
           [commands (make-command-registry)]
           [conditions (make-condition-service)]
           [display (make-display-update)]
           [configuration (make-configuration '())]
           [dispatch (make-dispatcher buffers views)]
           [packages (make-package-service)])
      (%make-host-state
        owner runtime buffers views commands conditions display dispatch packages configuration #f)))

  (define (host-state-close! state)
    (unless (host-state? state)
      (assertion-violation 'host-state-close! "expected a host state" state))
    (if (host-state-closed? state)
        #f
        (begin
          (package-service-close! (host-state-packages state))
          (runtime-close! (host-state-runtime state))
          (for-each buffer-close! (buffer-service-buffers (host-state-buffers state)))
          (for-each view-close! (view-service-views (host-state-views state)))
          (owner-close! (host-state-owner state))
          (host-state-closed?-set! state #t)
          #t)))

  ;; The frontend owns polling native events.  The host loop only drains
  ;; bounded runtime messages and therefore remains usable by headless tests
  ;; and by a future terminal frontend.
  (define (host-state-run! state . options)
    (unless (and (host-state? state) (not (host-state-closed? state)))
      (assertion-violation 'host-state-run! "host state is closed" state))
    (let ([handler (if (null? options) (lambda (message)
                                          (when (procedure? message) (message)))
                        (car options))]
          [limit (if (or (null? options) (null? (cdr options))) #f (cadr options))])
      (unless (procedure? handler)
        (assertion-violation 'host-state-run! "handler must be a procedure" handler))
      (runtime-drain! (host-state-runtime state) handler limit)))
)
