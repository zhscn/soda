(library (soda view plugin)
  (export make-view-update view-update? view-update-view-id view-update-start-state
          view-update-state view-update-editor-update view-update-damage view-update-occurrences
          view-update-damaged?
          make-view-plugin view-plugin? view-plugin-key view-plugin-create view-plugin-update
          view-plugin-destroy view-plugin-decorations view-plugin-display view-plugin-transform
          view-plugins-facet configuration-view-plugins)
  (import (rnrs) (soda kernel extension))

  ;; ViewUpdate is immutable input from the dispatcher publication boundary.
  (define-record-type
    (view-update %make-view-update view-update?)
    (fields view-id start-state state editor-update damage occurrences))
  (define (copy-list values) (reverse (reverse values)))
  (define make-view-update
    (case-lambda
      [(view-id start-state state editor-update damage)
       (make-view-update view-id start-state state editor-update damage '())]
      [(view-id start-state state editor-update damage occurrences)
    (unless (and (integer? view-id) (exact? view-id) (>= view-id 0) (list? damage))
      (assertion-violation 'make-view-update "invalid view update" view-id damage))
       (unless (list? occurrences)
         (assertion-violation 'make-view-update "occurrences must be a list" occurrences))
       (%make-view-update view-id start-state state editor-update (copy-list damage)
                          (copy-list occurrences))]))
  (define (view-update-damaged? update kind)
    (unless (and (view-update? update) (symbol? kind))
      (assertion-violation 'view-update-damaged? "expected a ViewUpdate and damage kind"
                           update kind))
    (memq kind (view-update-damage update)))

  ;; A ViewPlugin declaration owns only callbacks and its configuration key.
  ;; Instances and their mutable lifecycle belong to (soda view internal plugin).
  (define-record-type
    (view-plugin %make-view-plugin view-plugin?)
    (fields key create update destroy decorations display transform))
  (define (optional-procedure? value) (or (not value) (procedure? value)))
  (define make-view-plugin
    (case-lambda
      [(key create update destroy decorations)
       (make-view-plugin key create update destroy decorations #f #f)]
      [(key create update destroy decorations display)
       (make-view-plugin key create update destroy decorations display #f)]
      [(key create update destroy decorations display transform)
       (unless (and (symbol? key) (procedure? create) (optional-procedure? update)
                    (optional-procedure? destroy) (optional-procedure? decorations)
                    (optional-procedure? display) (optional-procedure? transform))
         (assertion-violation 'make-view-plugin "invalid ViewPlugin contract" key))
       (%make-view-plugin key create update destroy decorations display transform)]))

  (define (append-plugin-lists values) (fold-left append '() values))
  (define view-plugins-facet
    (make-facet 'view-plugins 'view '() append-plugin-lists eq?))
  (define (configuration-view-plugins configuration)
    (let loop ([plugins (configuration-facet configuration view-plugins-facet 'view)]
               [keys (make-eq-hashtable)] [result '()])
      (if (null? plugins)
          (reverse result)
          (let ([plugin (car plugins)])
            (unless (view-plugin? plugin)
              (assertion-violation 'configuration-view-plugins
                                   "view plugin facet contains a non-plugin" plugin))
            (let ([previous (hashtable-ref keys (view-plugin-key plugin) #f)])
              (cond [(not previous)
                     (hashtable-set! keys (view-plugin-key plugin) plugin)
                     (loop (cdr plugins) keys (cons plugin result))]
                    [(eq? previous plugin) (loop (cdr plugins) keys result)]
                    [else
                     (assertion-violation 'configuration-view-plugins
                                          "view plugin keys must identify one plugin definition"
                                          (view-plugin-key plugin) previous plugin)]))))))
)
