(library (soda kernel option)
  (export make-option-spec
          option-spec?
          option-spec-name
          option-spec-default
          option-spec-validator
          option-spec-compare
          option-spec-documentation
          option-spec-facet
          option-spec-compartment
          option-ref
          make-option-default-extension
          make-buffer-local-option-extension
          set-buffer-local-option-effect
          clear-buffer-local-option-effect)
  (import (rnrs)
          (soda kernel extension))

  ;; OptionSpec gives a named Buffer-local policy a typed immutable value.
  ;; Modes contribute low-precedence defaults; an explicit Buffer override is
  ;; isolated in the option's compartment and therefore survives mode changes.
  (define-record-type
    (option-spec %make-option-spec option-spec?)
    (fields
      (immutable name option-spec-name)
      (immutable default option-spec-default)
      (immutable validator option-spec-validator)
      (immutable compare option-spec-compare)
      (immutable documentation option-spec-documentation)
      (immutable facet option-spec-facet)
      (immutable compartment option-spec-compartment)))

  (define (first-value values default)
    (if (null? values) default (car values)))

  (define make-option-spec
    (case-lambda
      [(name default validator documentation)
       (make-option-spec name default validator equal? documentation)]
      [(name default validator compare documentation)
       (make-option-spec
         name default validator compare
         (lambda (values) (first-value values default))
         documentation)]
      [(name default validator compare combine documentation)
       (unless (and (symbol? name) (procedure? validator) (validator default)
                    (procedure? compare) (procedure? combine)
                    (string? documentation))
         (assertion-violation 'make-option-spec "invalid OptionSpec"
                              name default documentation))
       (let ([facet
              (make-facet
                name 'buffer default
                combine
                compare compare)])
         (%make-option-spec
           name default validator compare documentation facet
           (make-compartment name 'buffer)))]))

  (define (validate-option-value who spec value)
    (unless (and (option-spec? spec) ((option-spec-validator spec) value))
      (assertion-violation who "invalid Buffer-local option value" spec value)))

  (define (option-ref configuration spec)
    (unless (and (configuration? configuration) (option-spec? spec))
      (assertion-violation 'option-ref "expected a Configuration and OptionSpec"
                           configuration spec))
    (configuration-facet configuration (option-spec-facet spec) 'buffer))

  (define (make-option-default-extension spec value)
    (validate-option-value 'make-option-default-extension spec value)
    (make-facet-provider (option-spec-facet spec) value 'low))

  (define (make-buffer-local-option-extension spec value)
    (validate-option-value 'make-buffer-local-option-extension spec value)
    (make-facet-provider (option-spec-facet spec) value 'highest))

  (define (set-buffer-local-option-effect spec value)
    (make-compartment-reconfigure-effect
      (option-spec-compartment spec)
      (make-buffer-local-option-extension spec value)))

  (define (clear-buffer-local-option-effect spec)
    (unless (option-spec? spec)
      (assertion-violation 'clear-buffer-local-option-effect
                           "expected an OptionSpec" spec))
    (make-compartment-reconfigure-effect (option-spec-compartment spec) '()))
)
