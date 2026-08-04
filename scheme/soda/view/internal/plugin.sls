(library (soda view internal plugin)
  (export make-view-plugin-instance view-plugin-instance?
          view-plugin-instance-plugin view-plugin-instance-value
          view-plugin-instance-destroyed? view-plugin-instance-decorations
          view-plugin-instance-display-stream view-plugin-instance-display-transform
          view-plugin-instance-update! view-plugin-instance-destroy!)
  (import (rnrs) (soda view plugin) (soda view decoration) (soda view display))

  (define-record-type
    (view-plugin-instance %make-view-plugin-instance view-plugin-instance?)
    (fields plugin
            (mutable value view-plugin-instance-value view-plugin-instance-value-set!)
            (mutable decorations instance-decorations instance-decorations-set!)
            (mutable display-stream instance-display-stream instance-display-stream-set!)
            (mutable display-transform instance-display-transform instance-display-transform-set!)
            (mutable destroyed? view-plugin-instance-destroyed? instance-destroyed?-set!)))

  (define (decorations plugin value)
    (let ([procedure (view-plugin-decorations plugin)])
      (if procedure
          (let ([result (procedure value)])
            (unless (decoration-set? result)
              (assertion-violation 'view-plugin-instance-decorations
                                   "plugin decorations must be a DecorationSet" result))
            result)
          (make-decoration-set '()))))
  (define (stream plugin value)
    (let ([procedure (view-plugin-display plugin)])
      (if procedure
          (let ([result (procedure value)])
            (unless (or (not result) (display-stream? result))
              (assertion-violation 'view-plugin-instance-display-stream
                                   "plugin display must be a DisplayStream or #f" result))
            result)
          #f)))
  (define (transform plugin value)
    (let ([procedure (view-plugin-transform plugin)])
      (if procedure
          (let ([result (procedure value)])
            (unless (or (not result) (procedure? result))
              (assertion-violation 'view-plugin-instance-display-transform
                                   "plugin transform must be a procedure or #f" result))
            result)
          #f)))
  (define (make-view-plugin-instance plugin view)
    (unless (view-plugin? plugin)
      (assertion-violation 'make-view-plugin-instance "expected a ViewPlugin" plugin))
    (let ([value ((view-plugin-create plugin) view)])
      (%make-view-plugin-instance plugin value (decorations plugin value)
                                   (stream plugin value) (transform plugin value) #f)))
  (define (view-plugin-instance-display-stream instance)
    (and (not (view-plugin-instance-destroyed? instance)) (instance-display-stream instance)))
  (define (view-plugin-instance-display-transform instance)
    (and (not (view-plugin-instance-destroyed? instance)) (instance-display-transform instance)))
  (define (view-plugin-instance-decorations instance)
    (if (view-plugin-instance-destroyed? instance) '() (instance-decorations instance)))
  (define (view-plugin-instance-update! instance update)
    (unless (and (view-plugin-instance? instance) (not (view-plugin-instance-destroyed? instance))
                 (view-update? update))
      (assertion-violation 'view-plugin-instance-update! "invalid plugin update" instance update))
    (let ([plugin (view-plugin-instance-plugin instance)])
      (let ([procedure (view-plugin-update plugin)])
        (when procedure (procedure (view-plugin-instance-value instance) update)))
      (instance-decorations-set! instance (decorations plugin (view-plugin-instance-value instance)))
      (instance-display-stream-set! instance (stream plugin (view-plugin-instance-value instance)))
      (instance-display-transform-set! instance (transform plugin (view-plugin-instance-value instance)))
      (view-plugin-instance-value instance)))
  (define (view-plugin-instance-destroy! instance)
    (unless (view-plugin-instance? instance)
      (assertion-violation 'view-plugin-instance-destroy! "expected a ViewPlugin instance" instance))
    (if (view-plugin-instance-destroyed? instance) #f
        (let ([procedure (view-plugin-destroy (view-plugin-instance-plugin instance))])
          (when procedure (procedure (view-plugin-instance-value instance)))
          (instance-decorations-set! instance (make-decoration-set '()))
          (instance-display-stream-set! instance #f)
          (instance-display-transform-set! instance #f)
          (instance-destroyed?-set! instance #t) #t)))
)
