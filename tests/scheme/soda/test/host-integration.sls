(library (soda test host-integration)
  (export run-host-integration-tests!)
  (import (rnrs)
          (soda bootstrap)
          (soda host condition)
          (soda host buffer)
          (soda host dispatch)
          (soda host dispatch gate)
          (soda host internal operation)
          (soda host package)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host value)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel state)
          (soda support cleanup))

  (define (run-cleanup-test!)
    (let ([events '()]
          [failed? #f])
      (guard (condition [else (set! failed? #t)])
        (run-cleanups!
          (list
            (lambda () (set! events (cons 'first events)))
            (lambda () (error 'cleanup-test "expected cleanup failure"))
            (lambda () (set! events (cons 'last events))))))
      (unless (and failed? (equal? events '(last first)))
        (error 'host-integration-tests
               "cleanup did not run every action and retain the first failure"))))

  (define (run-dispatcher-observer-test!)
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [dispatch (host-state-dispatch state)]
           [owner (make-owner 'dispatcher-observer-test)]
           [conditions (host-state-conditions state)]
           [before (length (condition-service-entries conditions))]
           [observed #f]
           [_failing
            (dispatcher-add-host-listener!
              dispatch owner
              (lambda (update) (error 'dispatcher-observer-test "expected failure")))]
           [_following
            (dispatcher-add-host-listener!
              dispatch owner
              (lambda (update) (set! observed update)))])
      (dispatcher-dispatch-host!
        dispatch (make-resize-surface-operation (surface-id surface) '(81 . 24)))
      (unless (and observed
                   (= (length (condition-service-entries conditions)) (+ before 1)))
        (error 'host-integration-tests
               "a failing observer prevented later notification or condition capture"))
      (owner-close! owner)
      (soda-application-close! application)))

  (define (run-dispatch-gate-test!)
    (let ([gate (make-dispatch-gate)]
          [events '()])
      (define (record! event)
        (set! events (append events (list event))))
      (dispatch-gate-run!
        gate
        (lambda ()
          (record! 'publish-start)
          (dispatch-gate-notify!
            gate
            (lambda ()
              (record! 'notify)
              (dispatch-gate-run! gate (lambda () (record! 'deferred)))))
          (record! 'publish-end)))
      (unless (equal? events '(publish-start notify publish-end deferred))
        (error 'host-integration-tests
               "dispatch gate did not defer reentrant work" events))))

  ;; A package can ask for a temporary prompt or completion presentation, but
  ;; cannot retain a View when the target Surface cannot accept it.  The
  ;; Buffer remains the caller's resource until its normal cleanup path.
  (define (run-interaction-placement-rollback-test!)
    (let* ([state (make-host-state)]
           [host (make-package-host state)]
           [owner (make-owner 'interaction-placement-rollback-test)]
           [buffer
            (package-host-create-buffer!
              host owner " *interaction-test*" (make-document "")
              (make-configuration '()))]
           [views (host-state-views state)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (unless
            (and (not (package-host-create-interaction-view!
                        host owner buffer (make-configuration '()) 999 1))
                 (not (package-host-create-interaction-companion-view!
                        host owner buffer (make-configuration '()) 999 998 1))
                 (null? (view-service-views views)))
            (error 'host-integration-tests
                   "failed interaction placement retained an orphan View")))
        (lambda ()
          (package-host-close-buffer! host (buffer-id buffer))
          (owner-close! owner)
          (host-state-close! state)))))

  (define (run-host-integration-tests!)
    (run-cleanup-test!)
    (run-dispatcher-observer-test!)
    (run-dispatch-gate-test!)
    (run-interaction-placement-rollback-test!)))
