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
          facet-default
          facet-combine
          facet-compare
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
          make-compartment-entry
          compartment-entry?
          compartment-entry-compartment
          compartment-entry-extension
          make-configuration
          configuration?
          configuration-extensions
          configuration-fields
          configuration-facet
          configuration-reconfigure)
  (import (rnrs))

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
      (immutable default facet-default)
      (immutable combine facet-combine)
      (immutable compare facet-compare)))

  (define make-facet
    (case-lambda
      [(name default combine) (make-facet name default combine eq?)]
      [(name default combine compare)
    (unless (symbol? name)
      (assertion-violation 'make-facet "name must be a symbol" name))
    (unless (and (procedure? combine) (procedure? compare))
      (assertion-violation 'make-facet "combine must be a procedure" combine))
    (%make-facet name default combine compare)]))

  (define-record-type
    (state-effect %make-state-effect state-effect?)
    (fields
      (immutable type state-effect-type)
      (immutable value state-effect-value)
      (immutable mapper state-effect-map)))

  (define (make-state-effect type value . mapper)
    (unless (symbol? type)
      (assertion-violation 'make-state-effect "type must be a symbol" type))
    (%make-state-effect
      type value
      (if (null? mapper) (lambda (value change-desc) value) (car mapper))))

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
    (fields (immutable name compartment-name)))

  (define (make-compartment name)
    (unless (symbol? name)
      (assertion-violation 'make-compartment "name must be a symbol" name))
    (%make-compartment name))

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

  (define-record-type
    (configuration %make-configuration configuration?)
    (fields (immutable extensions configuration-extensions)))

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
    (%make-configuration (flatten extensions)))

  (define (configuration-fields configuration scope)
    (unless (configuration? configuration)
      (assertion-violation
        'configuration-fields "expected a configuration" configuration))
    (filter
      (lambda (field)
        (and (state-field? field) (eq? scope (state-field-scope field))))
      (configuration-extensions configuration)))

  (define precedence-order
    '((highest . 0) (high . 1) (default . 2) (low . 3) (lowest . 4)))

  (define (precedence-rank value)
    (cdr (assq value precedence-order)))

  (define (provider<? left right)
    (< (precedence-rank (facet-provider-precedence left))
       (precedence-rank (facet-provider-precedence right))))

  (define (configuration-facet configuration facet)
    (unless (and (configuration? configuration) (facet? facet))
      (assertion-violation
        'configuration-facet "expected a configuration and facet"
        configuration facet))
    (let ([values
            (map
              facet-provider-value
              (list-sort
                provider<?
                (filter
                  (lambda (extension)
                    (and (facet-provider? extension)
                         (eq? facet (facet-provider-facet extension))))
                  (configuration-extensions configuration))))])
      (if (null? values) (facet-default facet) ((facet-combine facet) values))))

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
          (make-configuration
            (replace-compartment extensions compartment extension))
          (make-configuration
            (append extensions (list (make-compartment-entry compartment extension)))))))
)
