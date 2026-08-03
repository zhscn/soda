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
          host-state-configuration
          host-state-closed?
          host-state-close!)
  (import (rnrs)
          (soda host buffer)
          (soda host command)
          (soda host condition)
          (soda host display)
          (soda host runtime)
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
           [configuration (make-configuration '())])
      (%make-host-state
        owner runtime buffers views commands conditions display configuration #f)))

  (define (host-state-close! state)
    (unless (host-state? state)
      (assertion-violation 'host-state-close! "expected a host state" state))
    (if (host-state-closed? state)
        #f
        (begin
          (runtime-close! (host-state-runtime state))
          (for-each buffer-close! (buffer-service-buffers (host-state-buffers state)))
          (for-each view-close! (view-service-views (host-state-views state)))
          (owner-close! (host-state-owner state))
          (host-state-closed?-set! state #t)
          #t)))
)
