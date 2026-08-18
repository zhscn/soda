(library (soda host dispatch publication)
  (export make-dispatch-publication
          dispatch-publication?
          dispatch-publication-run!
          dispatch-publication-set-error-reporter!
          dispatch-publication-set-editor-listener!
          dispatch-publication-set-host-listener!
          dispatch-publication-add-commit-participant!
          dispatch-publication-add-editor-listener!
          dispatch-publication-add-host-listener!
          dispatch-publication-publish-host!
          dispatch-publication-publish-editor!)
  (import (rnrs)
          (soda kernel extension)
          (soda host dispatch gate)
          (soda host value))

  (define-record-type
    (dispatch-observer %make-dispatch-observer dispatch-observer?)
    (fields (immutable procedure dispatch-observer-procedure)))

  (define-record-type
    (dispatch-publication %make-dispatch-publication dispatch-publication?)
    (fields
      (immutable gate dispatch-publication-gate)
      (mutable report-error! dispatch-publication-report-error!
               dispatch-publication-report-error!-set!)
      (mutable editor-listener dispatch-publication-editor-listener
               dispatch-publication-editor-listener-set!)
      (mutable host-listener dispatch-publication-host-listener
               dispatch-publication-host-listener-set!)
      ;; Commit participants run after the transaction has published immutable
      ;; Buffer/View state and before plugins or ordinary observers see it.
      ;; They maintain transaction-coupled package state such as savepoints.
      (mutable commit-participants dispatch-publication-commit-participants
               dispatch-publication-commit-participants-set!)
      (mutable editor-observers dispatch-publication-editor-observers
               dispatch-publication-editor-observers-set!)
      (mutable host-observers dispatch-publication-host-observers
               dispatch-publication-host-observers-set!)))

  (define (make-dispatch-publication editor-listener)
    (unless (or (not editor-listener) (procedure? editor-listener))
      (assertion-violation
        'make-dispatch-publication "expected a listener or #f" editor-listener))
    (%make-dispatch-publication
      (make-dispatch-gate) (lambda (source condition) #f)
      editor-listener #f '() '() '()))

  (define (dispatch-publication-run! publication thunk)
    (dispatch-gate-run! (dispatch-publication-gate publication) thunk))

  (define (dispatch-publication-set-error-reporter! publication reporter)
    (unless (and (dispatch-publication? publication) (procedure? reporter))
      (assertion-violation
        'dispatch-publication-set-error-reporter!
        "expected a DispatchPublication and reporter" publication reporter))
    (dispatch-publication-report-error!-set! publication reporter)
    reporter)

  (define (set-listener! who publication listener setter)
    (unless (and (dispatch-publication? publication)
                 (or (not listener) (procedure? listener)))
      (assertion-violation
        who "expected a DispatchPublication and listener or #f"
        publication listener))
    (setter publication listener)
    listener)

  (define (dispatch-publication-set-editor-listener! publication listener)
    (set-listener! 'dispatch-publication-set-editor-listener!
                   publication listener
                   dispatch-publication-editor-listener-set!))

  (define (dispatch-publication-set-host-listener! publication listener)
    (set-listener! 'dispatch-publication-set-host-listener!
                   publication listener
                   dispatch-publication-host-listener-set!))

  (define (add-observer! who publication owner listener access setter)
    (unless (and (dispatch-publication? publication) (owner? owner)
                 (procedure? listener))
      (assertion-violation
        who "expected a DispatchPublication, owner, and listener"
        publication owner listener))
    (owner-assert-active who owner)
    (let ([entry (%make-dispatch-observer listener)])
      (setter publication (append (access publication) (list entry)))
      (make-registration
        owner
        (lambda ()
          (setter
            publication
            (filter (lambda (item) (not (eq? item entry)))
                    (access publication)))))))

  (define (dispatch-publication-add-editor-listener! publication owner listener)
    (add-observer!
      'dispatch-publication-add-editor-listener! publication owner listener
      dispatch-publication-editor-observers
      dispatch-publication-editor-observers-set!))

  (define (dispatch-publication-add-commit-participant! publication owner listener)
    (add-observer!
      'dispatch-publication-add-commit-participant! publication owner listener
      dispatch-publication-commit-participants
      dispatch-publication-commit-participants-set!))

  (define (dispatch-publication-add-host-listener! publication owner listener)
    (add-observer!
      'dispatch-publication-add-host-listener! publication owner listener
      dispatch-publication-host-observers
      dispatch-publication-host-observers-set!))

  (define (report! publication source condition)
    (guard (ignored [else #f])
      ((dispatch-publication-report-error! publication) source condition)))

  (define (notify-one! publication source listener value)
    (guard
      (condition [else (report! publication source condition) #f])
      (listener value)))

  (define (notify-observers! publication source observers value)
    (for-each
      (lambda (entry)
        (notify-one! publication source
                     (dispatch-observer-procedure entry) value))
      observers))

  (define (dispatch-publication-publish-host! publication update)
    (dispatch-gate-notify!
      (dispatch-publication-gate publication)
      (lambda ()
        (let ([listener (dispatch-publication-host-listener publication)])
          (when listener
            (notify-one! publication '(host listener) listener update)))
        (notify-observers!
          publication '(host observer)
          (dispatch-publication-host-observers publication) update)))
    update)

  (define (dispatch-publication-publish-editor!
           publication update configuration notify-plugins!)
    (unless (procedure? notify-plugins!)
      (assertion-violation
        'dispatch-publication-publish-editor! "expected a plugin notifier"
        notify-plugins!))
    (dispatch-gate-notify!
      (dispatch-publication-gate publication)
      (lambda ()
        (notify-observers!
          publication '(editor commit-participant)
          (dispatch-publication-commit-participants publication) update)
        (notify-plugins! update)
        (let ([listener (dispatch-publication-editor-listener publication)])
          (when listener
            (notify-one! publication '(editor listener) listener update)))
        (notify-observers!
          publication '(editor observer)
          (dispatch-publication-editor-observers publication) update)
        (for-each
          (lambda (listener)
            (notify-one!
              publication '(editor update-listener) listener update))
          (configuration-facet configuration update-listeners-facet 'buffer))))
    update)
)
