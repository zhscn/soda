(library (soda kernel extension)
  (export make-state-field
          state-field?
          state-field-name
          state-field-scope
          state-field-create
          state-field-update
          state-field-compare
          state-field-provide
          make-facet
          facet?
          facet-name
          facet-scope
          facet-default
          facet-combine
          facet-compare
          facet-compare-input
          facet-compare-output
          make-facet-provider
          facet-provider?
          facet-provider-facet
          facet-provider-value
          facet-provider-precedence
          make-state-effect
          state-effect?
          state-effect-type
          state-effect-value
          state-effect-map
          state-effect-map-value
          state-effect-drop
          make-annotation
          annotation?
          annotation-key
          annotation-value
          transaction-filters-facet
          transaction-extenders-facet
          update-listeners-facet
          make-compartment
          compartment?
          compartment-name
          compartment-scope
          make-compartment-entry
          compartment-entry?
          compartment-entry-compartment
          compartment-entry-extension
          compartment-of
          compartment-reconfigure
          make-compartment-reconfigure-effect
          make-configuration
          configuration?
          configuration-extensions
          configuration-fields
          configuration-facet
          configuration-reconfigure
          configuration-apply-effects)
  (import (rnrs)
          (soda kernel change))

  (define (scope? value) (memq value '(buffer view host)))
  (define (precedence? value) (memq value '(highest high default low lowest)))

  (define-record-type
    (state-field %make-state-field state-field?)
    (fields
      (immutable name state-field-name)
      (immutable scope state-field-scope)
      (immutable create state-field-create)
      (immutable update state-field-update)
      (immutable compare state-field-compare)
      (immutable provide state-field-provide)))

  (define make-state-field
    (case-lambda
      [(name scope create update)
       (make-state-field name scope create update eq? #f)]
      [(name scope create update compare)
       (make-state-field name scope create update compare #f)]
      [(name scope create update compare provide)
       (unless (symbol? name)
         (assertion-violation 'make-state-field "name must be a symbol" name))
       (unless (scope? scope)
         (assertion-violation 'make-state-field "invalid state field scope" scope))
       (unless (and (procedure? create) (procedure? update) (procedure? compare))
         (assertion-violation 'make-state-field "field callbacks must be procedures" name))
       (unless (or (not provide) (procedure? provide))
         (assertion-violation 'make-state-field "provide must be a procedure" provide))
       (%make-state-field name scope create update compare provide)]))

  (define-record-type
    (facet %make-facet facet?)
    (fields
      (immutable name facet-name)
      (immutable scope facet-scope)
      (immutable default facet-default)
      (immutable combine facet-combine)
      (immutable compare-input facet-compare-input)
      (immutable compare-output facet-compare-output)))

  (define (facet-compare facet)
    (facet-compare-output facet))

  (define make-facet
    (case-lambda
      [(name default combine)
       (make-facet name 'buffer default combine eq? eq?)]
      [(name default combine compare)
       (make-facet name 'buffer default combine compare compare)]
      [(name scope default combine compare)
       (make-facet name scope default combine compare compare)]
      [(name scope default combine compare-input compare-output)
       (unless (symbol? name)
         (assertion-violation 'make-facet "name must be a symbol" name))
       (unless (scope? scope)
         (assertion-violation 'make-facet "invalid facet scope" scope))
       (unless (and (procedure? combine)
                    (procedure? compare-input)
                    (procedure? compare-output))
         (assertion-violation
           'make-facet "combine and comparison callbacks must be procedures"))
       (%make-facet
         name scope default combine compare-input compare-output)]))

  (define-record-type
    (state-effect %make-state-effect state-effect?)
    (fields
      (immutable type state-effect-type)
      (immutable value state-effect-value)
      (immutable mapper state-effect-map)))

  (define state-effect-drop (list 'state-effect-drop))

  (define (make-state-effect type value . mapper)
    (unless (symbol? type)
      (assertion-violation 'make-state-effect "type must be a symbol" type))
    (unless (or (null? mapper)
                (and (pair? mapper)
                     (null? (cdr mapper))
                     (procedure? (car mapper))))
      (assertion-violation
        'make-state-effect "mapper must be a single procedure" mapper))
    (%make-state-effect
      type value
      (if (null? mapper) (lambda (value change-desc) value) (car mapper))))

  ;; State effects are authored in the coordinates of the transaction's
  ;; starting document. Mapping creates a new immutable effect and retains
  ;; the original mapper for a later transaction mapping.
  (define (state-effect-map-value effect change-desc)
    (unless (state-effect? effect)
      (assertion-violation
        'state-effect-map-value "expected a state effect" effect))
    (unless (procedure? (state-effect-map effect))
      (assertion-violation
        'state-effect-map-value "state effect mapper is not callable" effect))
    (unless (change-desc? change-desc)
      (assertion-violation
        'state-effect-map-value "expected a ChangeDesc" change-desc))
    (let ([mapped
            ((state-effect-map effect) (state-effect-value effect) change-desc)])
      ;; The distinct drop token leaves #f available as an ordinary effect
      ;; value. Preserve identity when a mapper leaves the value untouched.
      (if (eq? mapped state-effect-drop)
          #f
          (if (eq? mapped (state-effect-value effect))
              effect
              (%make-state-effect
                (state-effect-type effect)
                mapped
                (state-effect-map effect))))))

  (define-record-type
    (annotation %make-annotation annotation?)
    (fields (immutable key annotation-key)
            (immutable value annotation-value)))

  (define (make-annotation key value)
    (unless (symbol? key)
      (assertion-violation 'make-annotation "key must be a symbol" key))
    (%make-annotation key value))

  (define (append-values values)
    (fold-left append '() values))

  ;; Providers contribute procedures of the form
  ;; resolved-transaction -> resolved-transaction | #f.  They observe the
  ;; complete normalized batch, rather than individual source specs.
  (define transaction-filters-facet
    (make-facet 'transaction-filters '() append-values))

  (define transaction-extenders-facet
    (make-facet 'transaction-extenders '() append-values))

  (define update-listeners-facet
    (make-facet 'update-listeners '() append-values))

  (define-record-type
    (facet-provider %make-facet-provider facet-provider?)
    (fields
      (immutable facet facet-provider-facet)
      (immutable value facet-provider-value)
      (immutable precedence facet-provider-precedence)))

  (define (make-facet-provider facet value . precedence)
    (unless (facet? facet)
      (assertion-violation 'make-facet-provider "expected a facet" facet))
    (let ([level (if (null? precedence) 'default (car precedence))])
      (unless (precedence? level)
        (assertion-violation 'make-facet-provider "invalid precedence" level))
      (%make-facet-provider facet value level)))

  (define-record-type
    (compartment %make-compartment compartment?)
    (fields
      (immutable name compartment-name)
      (immutable scope compartment-scope)))

  (define make-compartment
    (case-lambda
      [(name) (make-compartment name 'buffer)]
      [(name scope)
       (unless (symbol? name)
         (assertion-violation 'make-compartment "name must be a symbol" name))
       (unless (memq scope '(buffer view host))
         (assertion-violation 'make-compartment "invalid compartment scope" scope))
       (%make-compartment name scope)]))

  (define-record-type
    (compartment-entry %make-compartment-entry compartment-entry?)
    (fields
      (immutable compartment compartment-entry-compartment)
      (immutable extension compartment-entry-extension)))

  (define (make-compartment-entry compartment extension)
    (unless (compartment? compartment)
      (assertion-violation
        'make-compartment-entry "expected a compartment" compartment))
    (%make-compartment-entry compartment extension))

  (define (compartment-of compartment extension)
    (make-compartment-entry compartment extension))

  (define (make-compartment-reconfigure-effect compartment extension)
    (unless (compartment? compartment)
      (assertion-violation
        'make-compartment-reconfigure-effect
        "expected a compartment"
        compartment))
    (make-state-effect
      'compartment-reconfigure
      (make-compartment-entry compartment extension)))

  (define (compartment-reconfigure compartment extension)
    (make-compartment-reconfigure-effect compartment extension))

  (define-record-type
    (configuration %make-configuration configuration?)
    (fields
      (immutable extensions configuration-extensions)
      (immutable cache configuration-cache)
      (immutable previous configuration-previous)))

  (define (flatten extensions)
    (fold-right
      (lambda (extension result)
        (if (list? extension)
            (append (flatten extension) result)
            (cons extension result)))
      '()
      extensions))

  (define (make-configuration extensions)
    (unless (list? extensions)
      (assertion-violation 'make-configuration "extensions must be a list" extensions))
    (%make-configuration (flatten extensions) (make-eq-hashtable) #f))

  (define (make-derived-configuration extensions previous)
    (%make-configuration
      (flatten extensions) (make-eq-hashtable) previous))

  ;; Compartment entries remain in the raw extension list so they can be
  ;; replaced atomically. Queries see the extension contributed by each entry,
  ;; including nested extension lists.
  (define (effective-extensions extensions . seen)
    (let ([seen (if (null? seen) '() (car seen))])
      (fold-right
        (lambda (extension result)
          (append
            (cond
              [(compartment-entry? extension)
               (effective-extensions
                 (list (compartment-entry-extension extension)) seen)]
              [(list? extension)
               (effective-extensions extension seen)]
              [(and (state-field? extension)
                    (not (memq extension seen)))
               (let ([provide (state-field-provide extension)])
                 (if provide
                     (let ([provided (provide extension)])
                       (if provided
                           (cons extension
                                 (effective-extensions
                                   (if (list? provided)
                                       provided
                                       (list provided))
                                   (cons extension seen)))
                           (list extension)))
                     (list extension)))]
              [else (list extension)])
            result))
        '()
        extensions)))

  (define (configuration-fields configuration scope)
    (unless (configuration? configuration)
      (assertion-violation
        'configuration-fields "expected a configuration" configuration))
    (let ([fields
            (filter
              (lambda (field)
                (and (state-field? field)
                     (eq? scope (state-field-scope field))))
              (effective-extensions (configuration-extensions configuration)))])
      (let loop ([items fields] [seen '()] [result '()])
        (if (null? items)
            (reverse result)
            (if (memq (car items) seen)
                (loop (cdr items) seen result)
                (loop
                  (cdr items)
                  (cons (car items) seen)
                  (cons (car items) result)))))))

  (define precedence-order
    '((highest . 0) (high . 1) (default . 2) (low . 3) (lowest . 4)))

  (define (precedence-rank value)
    (cdr (assq value precedence-order)))

  (define (provider<? left right)
    (< (precedence-rank (facet-provider-precedence left))
       (precedence-rank (facet-provider-precedence right))))

  ;; Keep declaration order for providers with the same precedence.  The
  ;; resulting facet value is therefore deterministic even on Scheme
  ;; implementations whose generic list-sort is not stable.
  (define (stable-provider-sort providers)
    (define (insert-provider provider sorted)
      (cond
        [(null? sorted) (list provider)]
        [(provider<? provider (car sorted))
         (cons provider sorted)]
        [else
         (cons (car sorted)
               (insert-provider provider (cdr sorted)))]))
    (let loop ([items providers] [sorted '()])
      (if (null? items)
          sorted
          (loop (cdr items) (insert-provider (car items) sorted)))))

  (define (configuration-facet configuration facet . requested-scope)
    (unless (and (configuration? configuration) (facet? facet))
      (assertion-violation
        'configuration-facet "expected a configuration and facet"
        configuration facet))
    (unless (or (null? requested-scope)
                (and (pair? requested-scope)
                     (null? (cdr requested-scope))
                     (scope? (car requested-scope))))
      (assertion-violation
        'configuration-facet "scope must be buffer, view, host, or omitted"
        requested-scope))
    (let ([scope (if (null? requested-scope) #f (car requested-scope))])
      (if (and scope (not (eq? scope (facet-scope facet))))
          (facet-default facet)
          (let ([cached (hashtable-ref (configuration-cache configuration) facet #f)])
            (if cached
                (cdr cached)
                (let* ([values
                        (map
                          facet-provider-value
                          (stable-provider-sort
                            (filter
                              (lambda (extension)
                                (and (facet-provider? extension)
                                     (eq? facet (facet-provider-facet extension))))
                              (effective-extensions
                                (configuration-extensions configuration)))))]
                       [previous (configuration-previous configuration)]
                       [previous-entry
                        (and previous
                             (begin
                               (configuration-facet previous facet (facet-scope facet))
                               (hashtable-ref
                                 (configuration-cache previous) facet #f)))]
                       [same-inputs?
                        (and previous-entry
                             (= (length values) (length (car previous-entry)))
                             (for-all
                               (facet-compare-input facet)
                               values
                               (car previous-entry)))]
                       [combined
                        (if same-inputs?
                            (cdr previous-entry)
                            (if (null? values)
                                (facet-default facet)
                                ((facet-combine facet) values)))]
                       [output
                        (if (and previous-entry
                                 ((facet-compare-output facet)
                                  (cdr previous-entry) combined))
                            (cdr previous-entry)
                            combined)])
                  (hashtable-set!
                    (configuration-cache configuration)
                    facet
                    (cons values output))
                  output))))))

  (define (replace-compartment extensions compartment replacement)
    (if (null? extensions)
        '()
        (let ([extension (car extensions)])
          (if (and (compartment-entry? extension)
                   (eq? compartment (compartment-entry-compartment extension)))
              (cons (make-compartment-entry compartment replacement)
                    (cdr extensions))
              (cons extension
                    (replace-compartment
                      (cdr extensions) compartment replacement))))))

  (define (contains-compartment? extensions compartment)
    (and (pair? extensions)
         (or (and (compartment-entry? (car extensions))
                  (eq? compartment (compartment-entry-compartment (car extensions))))
             (contains-compartment? (cdr extensions) compartment))))

  (define (configuration-reconfigure configuration compartment extension)
    (unless (and (configuration? configuration) (compartment? compartment))
      (assertion-violation
        'configuration-reconfigure "expected a configuration and compartment"
        configuration compartment))
    (let ([extensions (configuration-extensions configuration)])
      (if (contains-compartment? extensions compartment)
          (make-derived-configuration
            (replace-compartment extensions compartment extension)
            configuration)
          (make-derived-configuration
            (append extensions (list (make-compartment-entry compartment extension)))
            configuration))))

  (define (configuration-apply-effects configuration effects . scope)
    (unless (configuration? configuration)
      (assertion-violation
        'configuration-apply-effects "expected a configuration" configuration))
    (let ([scope (if (null? scope) #f (car scope))])
      (unless (or (not scope) (memq scope '(buffer view host)))
        (assertion-violation
          'configuration-apply-effects "invalid configuration scope" scope))
      (fold-left
        (lambda (current effect)
          (if (and (state-effect? effect)
                   (eq? (state-effect-type effect) 'compartment-reconfigure)
                   (compartment-entry? (state-effect-value effect)))
              (let* ([entry (state-effect-value effect)]
                     [compartment (compartment-entry-compartment entry)])
                (if (or (not scope) (eq? scope (compartment-scope compartment)))
                    ;; Reconfiguring a compartment that was not present
                    ;; appends it to the configuration.
                    (configuration-reconfigure
                      current
                      compartment
                      (compartment-entry-extension entry))
                    current))
              current))
        configuration
        (if (list? effects) effects (list effects)))))
)
