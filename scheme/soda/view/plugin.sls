(library (soda view plugin)
  (export make-view-update
          view-update?
          view-update-view-id
          view-update-start-state
          view-update-state
          view-update-editor-update
          view-update-damage
          view-update-damaged?
          make-view-plugin
          view-plugin?
          view-plugin-key
          view-plugin-create
          view-plugin-update
          view-plugin-destroy
          view-plugin-decorations
          make-view-plugin-instance
          view-plugin-instance?
          view-plugin-instance-plugin
          view-plugin-instance-value
          view-plugin-instance-destroyed?
          view-plugin-instance-decorations
          view-plugin-instance-update!
          view-plugin-instance-destroy!
          view-plugins-facet
          configuration-view-plugins)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel value))

  ;; ViewUpdate is the only value passed from the host publication boundary to
  ;; render-local plugins.  Plugins cannot mutate BufferState or ViewState.
  (define-record-type
    (view-update %make-view-update view-update?)
    (fields view-id start-state state editor-update damage))

  (define (make-view-update view-id start-state state editor-update damage)
    (unless (and (exact-integer? view-id) (>= view-id 0) (list? damage))
      (assertion-violation 'make-view-update "invalid view update" view-id damage))
    (%make-view-update view-id start-state state editor-update (list-copy damage)))

  (define (view-update-damaged? update kind)
    (unless (and (view-update? update) (symbol? kind))
      (assertion-violation 'view-update-damaged? "expected a ViewUpdate and damage kind"
                           update kind))
    (memq kind (view-update-damage update)))

  (define-record-type
    (view-plugin %make-view-plugin view-plugin?)
    (fields key create update destroy decorations))

  (define (optional-procedure? value)
    (or (not value) (procedure? value)))

  (define (make-view-plugin key create update destroy decorations)
    (unless (and (symbol? key) (procedure? create)
                 (optional-procedure? update)
                 (optional-procedure? destroy)
                 (optional-procedure? decorations))
      (assertion-violation 'make-view-plugin "invalid ViewPlugin contract" key))
    (%make-view-plugin key create update destroy decorations))

  ;; A view-scoped facet gives every View its own instance set, even when
  ;; several Views share a Buffer configuration.
  (define (append-plugin-lists values)
    (fold-left append '() values))

  (define view-plugins-facet
    (make-facet 'view-plugins 'view '() append-plugin-lists eq?))

  (define (configuration-view-plugins configuration)
    (let loop ([plugins
                (configuration-facet configuration view-plugins-facet 'view)]
               [keys (make-eq-hashtable)]
               [result '()])
      (if (null? plugins)
          (reverse result)
          (let ([plugin (car plugins)])
            (unless (view-plugin? plugin)
              (assertion-violation
                'configuration-view-plugins
                "view plugin facet contains a non-plugin" plugin))
            (let ([previous (hashtable-ref keys (view-plugin-key plugin) #f)])
              (cond
                [(not previous)
                 (hashtable-set! keys (view-plugin-key plugin) plugin)
                 (loop (cdr plugins) keys (cons plugin result))]
                [(eq? previous plugin) (loop (cdr plugins) keys result)]
                [else
                 (assertion-violation
                   'configuration-view-plugins
                   "view plugin keys must identify one plugin definition"
                   (view-plugin-key plugin) previous plugin)]))))))

  (define-record-type
    (view-plugin-instance %make-view-plugin-instance view-plugin-instance?)
    (fields plugin
            (mutable value view-plugin-instance-value view-plugin-instance-value-set!)
            (mutable destroyed? view-plugin-instance-destroyed?
                     instance-destroyed?-set!)))

  (define (make-view-plugin-instance plugin view)
    (unless (view-plugin? plugin)
      (assertion-violation
        'make-view-plugin-instance "expected a ViewPlugin" plugin))
    (%make-view-plugin-instance plugin ((view-plugin-create plugin) view) #f))

  (define (view-plugin-instance-decorations instance)
    (unless (view-plugin-instance? instance)
      (assertion-violation
        'view-plugin-instance-decorations "expected a ViewPlugin instance" instance))
    (if (view-plugin-instance-destroyed? instance)
        '()
        (let ([procedure
                (view-plugin-decorations (view-plugin-instance-plugin instance))])
          (if procedure
              (procedure (view-plugin-instance-value instance))
              '()))))

  (define (view-plugin-instance-update! instance update)
    (unless (and (view-plugin-instance? instance)
                 (not (view-plugin-instance-destroyed? instance))
                 (view-update? update))
      (assertion-violation
        'view-plugin-instance-update! "invalid plugin update" instance update))
    (let ([procedure (view-plugin-update (view-plugin-instance-plugin instance))])
      (when procedure
        (procedure (view-plugin-instance-value instance) update))
      (view-plugin-instance-value instance)))

  (define (view-plugin-instance-destroy! instance)
    (unless (view-plugin-instance? instance)
      (assertion-violation
        'view-plugin-instance-destroy! "expected a ViewPlugin instance" instance))
    (if (view-plugin-instance-destroyed? instance)
        #f
        (let ([procedure (view-plugin-destroy (view-plugin-instance-plugin instance))])
          (when procedure
            (procedure (view-plugin-instance-value instance)))
          (instance-destroyed?-set! instance #t)
          #t))))
