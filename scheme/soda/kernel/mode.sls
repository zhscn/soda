(library (soda kernel mode)
  (export make-mode-spec
          mode-spec?
          mode-spec-id
          mode-spec-kind
          mode-spec-display-name
          mode-spec-parent
          mode-spec-extensions
          mode-spec-command-categories
          mode-spec-modeline-contribution
          mode-spec-activate
          mode-spec-deactivate
          mode-spec-extension-list
          buffer-mode-facet
          buffer-minor-modes-facet
          buffer-major-mode-compartment
          buffer-minor-modes-compartment
          make-buffer-mode-extension
          make-buffer-minor-modes-extension
          make-buffer-modes-extension
          set-buffer-major-mode-effect
          set-buffer-minor-modes-effect
          make-hook-spec
          hook-spec?
          hook-spec-name
          hook-spec-phase
          hook-spec-order
          hook-spec-procedure
          buffer-hooks-facet
          make-buffer-hook-extension)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel value))

  (define-record-type
    (mode-spec %make-mode-spec mode-spec?)
    (fields (immutable id mode-spec-id)
            (immutable kind mode-spec-kind)
            (immutable display-name mode-spec-display-name)
            (immutable parent mode-spec-parent)
            (immutable extensions mode-spec-extensions)
            (immutable command-categories mode-spec-command-categories)
            (immutable modeline-contribution mode-spec-modeline-contribution)
            (immutable activate mode-spec-activate)
            (immutable deactivate mode-spec-deactivate)))

  (define (optional-procedure? value) (or (not value) (procedure? value)))

  (define make-mode-spec
    (case-lambda
      [(id kind display-name parent extensions categories modeline)
       (make-mode-spec id kind display-name parent extensions categories modeline #f #f)]
      [(id kind display-name parent extensions categories modeline activate deactivate)
       (unless (and (symbol? id) (memq kind '(major minor)) (string? display-name)
                    (or (not parent)
                        (and (mode-spec? parent) (eq? kind (mode-spec-kind parent))))
                    (list? extensions) (list? categories)
                    (for-all symbol? categories)
                    (or (not modeline) (procedure? modeline) (string? modeline))
                    (optional-procedure? activate) (optional-procedure? deactivate))
         (assertion-violation 'make-mode-spec "invalid mode specification"
                              id kind display-name))
       (%make-mode-spec id kind display-name parent (list-copy extensions)
                        (list-copy categories) modeline activate deactivate)]))

  (define (mode-spec-extension-list spec)
    (append (if (mode-spec-parent spec)
                (mode-spec-extension-list (mode-spec-parent spec))
                '())
            (mode-spec-extensions spec)))

  (define (first-value values) (if (null? values) #f (car values)))
  (define (append-values values) (fold-left append '() values))

  (define buffer-mode-facet
    (make-facet 'buffer-mode 'buffer #f first-value eq? eq?))
  (define buffer-minor-modes-facet
    (make-facet 'buffer-minor-modes 'buffer '() append-values equal? equal?))
  (define buffer-major-mode-compartment
    (make-compartment 'buffer-major-mode 'buffer))
  (define buffer-minor-modes-compartment
    (make-compartment 'buffer-minor-modes 'buffer))

  (define (make-buffer-mode-extension spec)
    (unless (and (mode-spec? spec) (eq? (mode-spec-kind spec) 'major))
      (assertion-violation 'make-buffer-mode-extension "expected a major ModeSpec" spec))
    (append (list (make-facet-provider buffer-mode-facet spec))
            (mode-spec-extension-list spec)))

  (define (make-buffer-minor-modes-extension specs)
    (unless (and (list? specs)
                 (for-all (lambda (spec)
                            (and (mode-spec? spec) (eq? (mode-spec-kind spec) 'minor)))
                          specs))
      (assertion-violation 'make-buffer-minor-modes-extension
                           "expected minor ModeSpec values" specs))
    (append
      (list (make-facet-provider buffer-minor-modes-facet (list-copy specs)))
      (map mode-spec-extension-list specs)))

  (define (make-buffer-modes-extension major minor-modes)
    (unless (and (mode-spec? major) (eq? (mode-spec-kind major) 'major))
      (assertion-violation 'make-buffer-modes-extension "expected a major ModeSpec" major))
    (list
      (compartment-of buffer-major-mode-compartment
                      (make-buffer-mode-extension major))
      (compartment-of buffer-minor-modes-compartment
                      (make-buffer-minor-modes-extension minor-modes))))

  (define (set-buffer-major-mode-effect spec)
    (make-compartment-reconfigure-effect
      buffer-major-mode-compartment (make-buffer-mode-extension spec)))

  (define (set-buffer-minor-modes-effect specs)
    (make-compartment-reconfigure-effect
      buffer-minor-modes-compartment (make-buffer-minor-modes-extension specs)))

  (define hook-phases
    '(before-major-mode-change after-major-mode-change major-mode
      minor-mode-enabled minor-mode-disabled buffer-configuration-changed buffer-close))

  (define-record-type
    (hook-spec %make-hook-spec hook-spec?)
    (fields (immutable name hook-spec-name)
            (immutable phase hook-spec-phase)
            (immutable order hook-spec-order)
            (immutable procedure hook-spec-procedure)))

  (define (make-hook-spec name phase order procedure)
    (unless (and (symbol? name) (memq phase hook-phases)
                 (integer? order) (exact? order) (procedure? procedure))
      (assertion-violation 'make-hook-spec "invalid Buffer-local HookSpec"
                           name phase order procedure))
    (%make-hook-spec name phase order procedure))

  (define buffer-hooks-facet
    (make-facet 'buffer-hooks 'buffer '() append-values equal? equal?))

  (define (make-buffer-hook-extension hooks)
    (unless (and (list? hooks) (for-all hook-spec? hooks))
      (assertion-violation 'make-buffer-hook-extension "expected HookSpec values" hooks))
    (make-facet-provider buffer-hooks-facet (list-copy hooks)))
)
