(library (soda kernel extension)
  (export make-state-field
          state-field?
          state-field-name
          state-field-scope
          state-field-create
          state-field-update
          state-field-compare
          make-facet
          facet?
          facet-name
          facet-default
          facet-combine
          make-facet-provider
          facet-provider?
          facet-provider-facet
          facet-provider-value
          facet-provider-precedence
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
      (immutable compare state-field-compare)))

  (define make-state-field
    (case-lambda
      [(name scope create update)
       (make-state-field name scope create update eq?)]
      [(name scope create update compare)
       (unless (symbol? name)
         (assertion-violation 'make-state-field "name must be a symbol" name))
       (unless (scope? scope)
         (assertion-violation 'make-state-field "invalid state field scope" scope))
       (unless (and (procedure? create) (procedure? update) (procedure? compare))
         (assertion-violation 'make-state-field "field callbacks must be procedures" name))
       (%make-state-field name scope create update compare)]))

  (define-record-type
    (facet %make-facet facet?)
    (fields
      (immutable name facet-name)
      (immutable default facet-default)
      (immutable combine facet-combine)))

  (define (make-facet name default combine)
    (unless (symbol? name)
      (assertion-violation 'make-facet "name must be a symbol" name))
    (unless (procedure? combine)
      (assertion-violation 'make-facet "combine must be a procedure" combine))
    (%make-facet name default combine))

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
    ((facet-combine facet)
      (map
        facet-provider-value
        (list-sort
          provider<?
          (filter
            (lambda (extension)
              (and (facet-provider? extension)
                   (eq? facet (facet-provider-facet extension))))
            (configuration-extensions configuration))))))

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

  (define (configuration-reconfigure configuration compartment extension)
    (unless (and (configuration? configuration) (compartment? compartment))
      (assertion-violation
        'configuration-reconfigure "expected a configuration and compartment"
        configuration compartment))
    (make-configuration
      (replace-compartment
        (configuration-extensions configuration)
        compartment
        extension)))
)
