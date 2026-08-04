(library (soda test buffer-ui)
  (export run-buffer-ui-tests!)
  (import (rnrs)
          (soda bootstrap)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel range-set)
          (soda kernel state)
          (soda kernel selection)
          (soda kernel view-state)
          (soda host command)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal buffer-attachment)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages buffer-ui))

  (define (make-test-buffer buffers owner name)
    (buffer-service-create!
      buffers owner name (make-document "") (make-configuration '())))

  (define (run-buffer-catalog-test!)
    (let* ([state (make-host-state)]
           [owner (make-owner 'buffer-catalog-test)]
           [buffers (host-state-buffers state)]
           [key (make-buffer-key 'test "shared")]
           [builds 0]
           [first
            (buffer-service-open-or-create!
              buffers owner key
              (lambda ()
                (set! builds (+ builds 1))
                (make-test-buffer buffers owner "*shared*")))]
           [second
            (buffer-service-open-or-create!
              buffers owner key
              (lambda ()
                (set! builds (+ builds 1))
                (make-test-buffer buffers owner "*incorrect*")))])
      (unless (and (= builds 1) (= (buffer-id first) (buffer-id second))
                   (eq? (buffer-lifecycle first) 'live))
        (error 'buffer-ui-tests "BufferKey did not reuse one live Buffer"))
      (unless (buffer-service-close-buffer! buffers (buffer-id first))
        (error 'buffer-ui-tests "keyed Buffer did not close"))
      (unless (and (not (buffer-service-find-key buffers key #f))
                   (not (buffer-service-ref buffers (buffer-id first) #f))
                   (eq? (buffer-lifecycle first) 'closed))
        (error 'buffer-ui-tests "closing a Buffer retained catalog state"))
      (let ([replacement
             (buffer-service-open-or-create!
               buffers owner key
               (lambda ()
                 (set! builds (+ builds 1))
                 (make-test-buffer buffers owner "*replacement*")))])
        (unless (and (= builds 2) (not (= (buffer-id first) (buffer-id replacement))))
          (error 'buffer-ui-tests "catalog did not create after key removal")))
      (owner-close! owner)
      (host-state-close! state)))

  (define (run-buffer-attachment-test!)
    (let* ([state (make-host-state)]
           [buffer-owner (make-owner 'buffer-attachment-buffer-test)]
           [attachment-owner (make-owner 'buffer-attachment-owner-test)]
           [buffers (host-state-buffers state)]
           [attachments (host-state-buffer-attachments state)]
           [buffer (make-test-buffer buffers buffer-owner "*attached*")]
           [allow? #f]
           [destroyed 0]
           [attachment
            (buffer-attachment-service-install!
              attachments attachment-owner buffer 'watch 7
              (lambda (ignored) allow?)
              #f
              (lambda () (set! destroyed (+ destroyed 1))))])
      (unless (and (= (buffer-attachment-buffer-id attachment) (buffer-id buffer))
                   (= (buffer-attachment-generation attachment) 7))
        (error 'buffer-ui-tests "attachment declaration lost Buffer identity"))
      (when (buffer-service-close-buffer! buffers (buffer-id buffer))
        (error 'buffer-ui-tests "attachment close query did not keep Buffer live"))
      (unless (and (buffer-live? buffer)
                   (buffer-attachment-service-ref attachments (buffer-id buffer) 'watch #f)
                   (= destroyed 0))
        (error 'buffer-ui-tests "rejected close damaged Buffer attachments"))
      (set! allow? #t)
      (unless (buffer-service-close-buffer! buffers (buffer-id buffer))
        (error 'buffer-ui-tests "accepted attachment close did not close Buffer"))
      (unless (and (= destroyed 1)
                   (not (buffer-attachment-service-ref attachments (buffer-id buffer) 'watch #f)))
        (error 'buffer-ui-tests "attachment was not destroyed before Buffer release"))
      (owner-close! attachment-owner)
      (owner-close! buffer-owner)
      (host-state-close! state)))

  (define (run-owner-detach-test!)
    (let* ([state (make-host-state)]
           [buffer-owner (make-owner 'buffer-owner-test)]
           [attachment-owner (make-owner 'attachment-owner-test)]
           [buffers (host-state-buffers state)]
           [attachments (host-state-buffer-attachments state)]
           [buffer (make-test-buffer buffers buffer-owner "*owner-detach*")]
           [destroyed 0])
      (buffer-attachment-service-install!
        attachments attachment-owner buffer 'producer 0 #f #f
        (lambda () (set! destroyed (+ destroyed 1))))
      (owner-close! attachment-owner)
      (unless (and (= destroyed 1)
                   (not (buffer-attachment-service-ref attachments (buffer-id buffer) 'producer #f))
                   (buffer-live? buffer))
        (error 'buffer-ui-tests "owner cleanup did not detach only its attachment"))
      (owner-close! buffer-owner)
      (host-state-close! state)))

  (define (run-item-and-policy-test!)
    (let* ([state (make-host-state)]
           [owner (make-owner 'buffer-item-test)]
           [buffers (host-state-buffers state)]
           [dispatch (host-state-dispatch state)]
           [authority (make-edit-authority owner 'refresh)]
           [policy (make-buffer-edit-policy 'reject #f authority)]
            [configuration
            (make-configuration
              (list (generated-projection-extension)
                    (make-buffer-edit-policy-extension policy)))]
           [buffer
            (buffer-service-create! buffers owner "*items*"
                                    (make-document "abc") configuration)]
           [view (view-service-create! (host-state-views state) owner buffer configuration)]
           [item (make-buffer-item 'test 'alpha 'entry '(payload) '(open) 'open)]
           [ranges (make-range-set (list (make-range-value 0 3 item)))])
      (dispatcher-dispatch!
        dispatch
        (make-transaction-spec
          (buffer-id buffer) #f (buffer-state-generation (buffer-state buffer))
          (make-change-set 3 '()) #f (list (make-buffer-items-effect ranges)) '()))
      (unless (eq? (buffer-item-at-point (buffer-state buffer) 1) item)
        (error 'buffer-ui-tests "semantic item projection was not published"))
      ;; An ordinary edit maps item ranges but the read-only policy rejects it.
      (when (dispatcher-dispatch!
              dispatch
              (make-transaction-spec
                (buffer-id buffer) #f (buffer-state-generation (buffer-state buffer))
                (make-change-set 3 (list (make-text-change 0 0 "x"))) #f '() '()))
        (error 'buffer-ui-tests "read-only EditPolicy accepted content change"))
      (unless (and (string=? (snapshot-string (buffer-state-document (buffer-state buffer))) "abc")
                   (eq? (buffer-item-at-point (buffer-state buffer) 1) item))
        (error 'buffer-ui-tests "rejected edit changed generated Buffer state"))
      (dispatcher-dispatch!
        dispatch
        (make-transaction-spec
          (buffer-id buffer) #f (buffer-state-generation (buffer-state buffer))
          (make-change-set 3 (list (make-text-change 0 0 "x"))) #f '()
          (list (make-edit-authority-annotation authority))))
      (unless (and (string=? (snapshot-string (buffer-state-document (buffer-state buffer))) "xabc")
                   (eq? (buffer-item-at-point (buffer-state buffer) 2) item))
        (error 'buffer-ui-tests "authorized edit did not map semantic item ranges"))
      (dispatcher-dispatch-view!
        dispatch
        (make-view-transaction-spec
          (view-id view) (view-state-generation (view-state view))
          (make-selection (list (make-selection-range 2 2))) #f #f '() '() #f))
      (let* ([position (semantic-position-at-point (buffer-state buffer) 2)]
             [projected-item (make-buffer-item 'test 'alpha 'entry '() '(open) 'open)]
             [update
              (make-projection-update
                9 "result"
                (make-range-set (list (make-range-value 0 6 projected-item)))
                '() '())])
        (dispatcher-dispatch!
          dispatch
          (make-projection-transaction-spec
            (buffer-id buffer) #f (buffer-state buffer) update
            (list (make-edit-authority-annotation authority))
            (list (cons (view-id view) position))))
        (unless (and (string=? (snapshot-string (buffer-state-document (buffer-state buffer))) "result")
                     (eq? (buffer-state-field (buffer-state buffer) generated-projection-field) update)
                     (eq? (buffer-item-at-point (buffer-state buffer) 1) projected-item)
                     (= (selection-range-head
                          (selection-primary-range (view-state-selection (view-state view))))
                        1))
          (error 'buffer-ui-tests "generated projection did not atomically restore item position")))
      (let* ([actions (make-buffer-item-action-service)]
             [activated #f])
        (buffer-item-action-register!
          actions owner 'open
          (lambda (received context)
            (set! activated (and (eq? received item) (command-context? context)))
            (command-handled)))
        (buffer-item-action-invoke actions 'open item
                                   (make-command-context 0 (buffer-id buffer) 'buffer-ui-test))
        (unless activated
          (error 'buffer-ui-tests "semantic item action did not receive stable item identity")))
      (owner-close! owner)
      (host-state-close! state)))

  (define (run-bootstrap-buffer-ui-test!)
    (let* ([application (make-soda-application)]
           [buffer (soda-application-buffer application)]
           [actions (soda-application-buffer-item-actions application)])
      (unless (and (pair? (buffer-item-ranges (buffer-state buffer)))
                   (buffer-item-action-service? actions))
        (error 'buffer-ui-tests "bootstrap did not install standard Buffer UI extensions"))
      (soda-application-close! application)))

  (define (run-buffer-ui-tests!)
    (run-buffer-catalog-test!)
    (run-buffer-attachment-test!)
    (run-owner-detach-test!)
    (run-item-and-policy-test!)
    (run-bootstrap-buffer-ui-test!)))
