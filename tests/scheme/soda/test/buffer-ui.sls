(library (soda test buffer-ui)
  (export run-buffer-ui-tests!)
  (import (rnrs)
          (only (chezscheme) string-set!)
          (soda bootstrap)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel range-set)
          (soda kernel state)
          (soda kernel selection)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal buffer-attachment)
          (soda host internal mode)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages buffer-mode)
          (soda packages edit-policy)
          (soda packages generated-buffer)
          (soda packages buffer-item))

  (define (make-test-buffer buffers owner name)
    (buffer-service-create!
      buffers owner name (make-document "") (make-configuration '())))

  (define (run-buffer-catalog-test!)
    (let* ([state (make-host-state)]
           [owner (make-owner 'buffer-catalog-test)]
           [buffers (host-state-buffers state)]
           [key-input (string-copy "shared")]
           [key (make-buffer-key 'test key-input)]
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
      (string-set! key-input 0 #\X)
      (unless (eq? (buffer-service-find-key buffers key #f) first)
        (error 'buffer-ui-tests "BufferKey retained mutable identity input"))
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

  (define (run-attachment-service-ownership-test!)
    (let* ([first (make-host-state)]
           [second (make-host-state)]
           [owner (make-owner 'foreign-attachment-test)]
           [buffer-owner (make-owner 'foreign-buffer-test)]
           [foreign-buffer
            (make-test-buffer (host-state-buffers second) buffer-owner "*foreign*")]
           [rejected? #f])
      (guard (condition [else (set! rejected? #t)])
        (buffer-attachment-service-install!
          (host-state-buffer-attachments first) owner foreign-buffer 'foreign 0 #f #f
          (lambda () #f)))
      (unless rejected?
        (error 'buffer-ui-tests "attachment service accepted a foreign Buffer"))
      (owner-close! owner)
      (owner-close! buffer-owner)
      (host-state-close! first)
      (host-state-close! second)))

  (define (run-close-reentrancy-test!)
    (let* ([state (make-host-state)]
           [owner (make-owner 'close-reentrancy-test)]
           [buffers (host-state-buffers state)]
           [attachments (host-state-buffer-attachments state)]
           [key (make-buffer-key 'test "reentrant")]
           [original
            (buffer-service-open-or-create!
              buffers owner key
              (lambda () (make-test-buffer buffers owner "*original*")))]
           [replacement #f])
      (buffer-attachment-service-install!
        attachments owner original 'replacement 0 #f #f
        (lambda ()
          (set! replacement
                (buffer-service-open-or-create!
                  buffers owner key
                  (lambda () (make-test-buffer buffers owner "*replacement*"))))))
      (unless (buffer-service-close-buffer! buffers (buffer-id original))
        (error 'buffer-ui-tests "close did not accept a reentrant replacement"))
      (unless (and replacement
                   (not (= (buffer-id original) (buffer-id replacement)))
                   (eq? (buffer-service-find-key buffers key #f) replacement))
        (error 'buffer-ui-tests "close removed the replacement BufferKey binding"))
      (unless (and (host-state-close! state) (not (buffer-live? replacement)))
        (error 'buffer-ui-tests "HostState close retained a replacement Buffer"))
      (owner-close! owner)
      ))

  (define (run-host-close-veto-test!)
    (let* ([state (make-host-state)]
           [buffer-owner (make-owner 'host-close-buffer-test)]
           [attachment-owner (make-owner 'host-close-attachment-test)]
           [buffer (make-test-buffer (host-state-buffers state) buffer-owner "*veto*")]
           [allow? #f])
      (buffer-attachment-service-install!
        (host-state-buffer-attachments state) attachment-owner buffer 'veto 0
        (lambda (ignored) allow?) #f (lambda () #f))
      (when (host-state-close! state)
        (error 'buffer-ui-tests "HostState closed despite a Buffer close veto"))
      (unless (and (not (host-state-closed? state)) (buffer-live? buffer))
        (error 'buffer-ui-tests "close veto left HostState partially closed"))
      (set! allow? #t)
      (unless (host-state-close! state)
        (error 'buffer-ui-tests "HostState did not close after veto resolution"))
      (owner-close! attachment-owner)
      (owner-close! buffer-owner)))

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

  (define (run-mode-lifecycle-test!)
    (let* ([state (make-host-state)]
           [owner (make-owner 'mode-lifecycle-test)]
           [events '()]
           [record! (lambda (event) (set! events (append events (list event))))]
           [hook
            (lambda (name phase order)
              (make-hook-spec
                name phase order
                (lambda (event)
                  (unless (and (mode-event? event)
                               (buffer? (mode-event-buffer event)))
                    (error 'buffer-ui-tests "mode hook received an invalid event"))
                  (record! name))))]
           [first
            (make-mode-spec
              'first-mode 'major "First" #f
              (list (make-buffer-hook-extension
                      (list (hook 'first-before 'before-major-mode-change 0)
                            (hook 'first-close 'buffer-close 0))))
              '(first) #f
              (lambda (buffer instance-owner)
                (record! 'first-activate)
                (owner-add-cleanup! instance-owner
                                    (lambda () (record! 'first-cleanup))))
              (lambda (buffer instance-owner) (record! 'first-deactivate)))]
           [second
            (make-mode-spec
              'second-mode 'major "Second" #f
              (list (make-buffer-hook-extension
                      (list (hook 'second-after-late 'after-major-mode-change 10)
                            (hook 'second-after-early 'after-major-mode-change -10)
                            (hook 'second-major 'major-mode 0)
                            (hook 'second-configuration
                                  'buffer-configuration-changed 0)
                            (hook 'second-close 'buffer-close 0))))
              '(second) #f
              (lambda (buffer instance-owner)
                (record! 'second-activate)
                (owner-add-cleanup! instance-owner
                                    (lambda () (record! 'second-cleanup))))
              (lambda (buffer instance-owner) (record! 'second-deactivate)))]
           [configuration
            (make-configuration (make-buffer-modes-extension first '()))]
           [buffer
            (buffer-service-create!
              (host-state-buffers state) owner "*modes*" (make-document "")
              configuration)]
           [first-instance
            (car (mode-service-instances (host-state-modes state) (buffer-id buffer)))])
      (command-runtime-register-command!
        (host-state-command-runtime state)
        (make-command-definition
          'test.global (lambda (context) (command-handled)) owner
          "Global test command." 'test #f 'global))
      (command-runtime-register-command!
        (host-state-command-runtime state)
        (make-command-definition
          'test.first-mode (lambda (context) (command-handled)) owner
          "First-mode test command." 'first #f 'mode))
      (command-runtime-register-command!
        (host-state-command-runtime state)
        (make-command-definition
          'test.second-mode (lambda (context) (command-handled)) owner
          "Second-mode test command." 'second #f 'mode))
      (let ([context (make-command-context #f (buffer-id buffer) 'mode-test)])
        ;; A query context carries the immutable published BufferState just as
        ;; an ordinary frontend command context does.
        (set! context
              (make-command-context
                #f #f #f #f (buffer-id buffer) (buffer-state buffer) #f #f
                '() #f #f 'mode-test))
        (unless (and (command-runtime-command-available?
                       (host-state-command-runtime state) 'test.global context)
                     (command-runtime-command-available?
                       (host-state-command-runtime state) 'test.first-mode context)
                     (not (command-runtime-command-available?
                            (host-state-command-runtime state)
                            'test.second-mode context)))
          (error 'buffer-ui-tests "command availability ignored the active mode")))
      (unless (and (mode-instance? first-instance)
                   (eq? (mode-instance-spec first-instance) first)
                   (owner-active? (mode-instance-owner first-instance)))
        (error 'buffer-ui-tests "Buffer creation did not activate its major mode"))
      (dispatcher-dispatch!
        (host-state-dispatch state)
        (make-transaction-spec
          (buffer-id buffer) #f (buffer-state-generation (buffer-state buffer))
          (make-change-set 0 '()) #f (list (set-buffer-major-mode-effect second)) '()))
      (let ([second-instance
             (car (mode-service-instances (host-state-modes state) (buffer-id buffer)))])
        (unless (and (not (eq? first-instance second-instance))
                     (not (owner-active? (mode-instance-owner first-instance)))
                     (owner-active? (mode-instance-owner second-instance))
                     (equal? events
                             '(first-activate
                               first-before first-deactivate first-cleanup
                               second-activate second-after-early second-after-late
                               second-major second-configuration)))
          (error 'buffer-ui-tests "major-mode transition order or ownership differs"
                 events))
        (let ([context
               (make-command-context
                 #f #f #f #f (buffer-id buffer) (buffer-state buffer) #f #f
                 '() #f #f 'mode-test)])
          (unless (and (command-runtime-command-available?
                         (host-state-command-runtime state)
                         'test.second-mode context)
                       (not (command-runtime-command-available?
                              (host-state-command-runtime state)
                              'test.first-mode context)))
            (error 'buffer-ui-tests
                   "command availability retained the previous major mode")))
        (set! events '())
        (dispatcher-dispatch!
          (host-state-dispatch state)
          (make-transaction-spec
            (buffer-id buffer) #f (buffer-state-generation (buffer-state buffer))
            (make-change-set 0 '()) #f '() '()))
        (unless (and (null? events)
                     (eq? second-instance
                          (car (mode-service-instances
                                 (host-state-modes state) (buffer-id buffer)))))
          (error 'buffer-ui-tests "unchanged mode configuration was not idempotent"))
        (buffer-service-close-buffer! (host-state-buffers state) (buffer-id buffer))
        (unless (and (equal? events '(second-close second-deactivate second-cleanup))
                     (not (owner-active? (mode-instance-owner second-instance)))
                     (null? (mode-service-instances
                              (host-state-modes state) (buffer-id buffer))))
          (error 'buffer-ui-tests "Buffer close did not retire its ModeInstance" events)))
      (owner-close! owner)
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
             [projected-text (string-copy "result")]
             [update
              (make-projection-update
                9 projected-text
                (make-range-set (list (make-range-value 0 6 projected-item)))
                '() '())])
        (string-set! projected-text 0 #\X)
        (unless (string=? (projection-update-text update) "result")
          (error 'buffer-ui-tests "ProjectionUpdate retained mutable text"))
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
          (error 'buffer-ui-tests "generated projection did not atomically restore item position"))
        (let ([stale
               (make-projection-update
                 8 "stale"
                 (make-range-set (list (make-range-value 0 5 projected-item)))
                 '() '())])
          (when (dispatcher-dispatch!
                  dispatch
                  (make-projection-transaction-spec
                    (buffer-id buffer) #f (buffer-state buffer) stale
                    (list (make-edit-authority-annotation authority))))
            (error 'buffer-ui-tests "stale ProjectionUpdate was published"))
          (unless (string=? (snapshot-string (buffer-state-document (buffer-state buffer))) "result")
            (error 'buffer-ui-tests "stale ProjectionUpdate replaced document text"))))
      (let* ([actions (make-buffer-item-action-service)]
             [activated #f]
             [other-item (make-buffer-item 'other 'alpha 'entry '() '(open) 'open)]
             [other-activated #f])
        (buffer-item-action-register!
          actions owner 'test 'open
          (lambda (received context generation)
            (set! activated (and (eq? received item) (command-context? context)))
            (command-handled)))
        (buffer-item-action-register!
          actions owner 'other 'open
          (lambda (received context generation)
            (set! other-activated (and (eq? received other-item) (command-context? context)))
            (command-handled)))
        (buffer-item-action-invoke actions 'open item
                                   (make-command-context 0 (buffer-id buffer) 'buffer-ui-test))
        (buffer-item-action-invoke actions 'open other-item
                                   (make-command-context 0 (buffer-id buffer) 'buffer-ui-test))
        (unless (and activated other-activated)
          (error 'buffer-ui-tests "semantic item actions did not dispatch by provider identity")))
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
    (run-attachment-service-ownership-test!)
    (run-close-reentrancy-test!)
    (run-host-close-veto-test!)
    (run-owner-detach-test!)
    (run-mode-lifecycle-test!)
    (run-item-and-policy-test!)
    (run-bootstrap-buffer-ui-test!)))
