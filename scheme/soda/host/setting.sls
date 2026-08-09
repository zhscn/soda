(library (soda host setting)
  (export make-setting-schema
          setting-schema?
          setting-schema-name
          setting-schema-type
          setting-schema-default
          setting-schema-scopes
          setting-schema-parse
          setting-schema-valid?
          make-setting-value
          setting-value?
          setting-value-schema
          setting-value-name
          setting-value-value
          setting-value-scope
          setting-value-source
          setting-value-extension
          setting-error?
          setting-error-name
          setting-error-source
          setting-error-input
          setting-error-reason)
  (import (rnrs)
          (soda kernel location))

  (define valid-scopes '(application workspace buffer view))
  (define builtin-types
    '(any boolean integer nonnegative-integer positive-integer string symbol))

  (define (type-valid? type value)
    (if (procedure? type)
        (and (type value) #t)
        (case type
          [(any) #t]
          [(boolean) (boolean? value)]
          [(integer) (and (integer? value) (exact? value))]
          [(nonnegative-integer)
           (and (integer? value) (exact? value) (>= value 0))]
          [(positive-integer)
           (and (integer? value) (exact? value) (> value 0))]
          [(string) (string? value)]
          [(symbol) (symbol? value)]
          [else #f])))

  (define-record-type
    (setting-schema %make-setting-schema setting-schema?)
    (fields
      (immutable name setting-schema-name)
      (immutable type setting-schema-type)
      (immutable default setting-schema-default)
      (immutable scopes setting-schema-scopes)
      (immutable parser setting-schema-parser)
      (immutable validator setting-schema-validator)
      (immutable materialize setting-schema-materialize)))

  (define setting-schema-parse setting-schema-parser)

  (define (copy-list values)
    (reverse (reverse values)))

  (define (make-setting-schema name type default scopes parser validator materialize)
    (unless (and (symbol? name)
                 (or (procedure? type) (memq type builtin-types))
                 (list? scopes) (pair? scopes)
                 (for-all (lambda (scope) (memq scope valid-scopes)) scopes)
                 (= (length scopes) (length (delete-duplicates scopes)))
                 (or (not parser) (procedure? parser))
                 (or (not validator) (procedure? validator))
                 (procedure? materialize)
                 (type-valid? type default)
                 (or (not validator) (validator default)))
      (assertion-violation
        'make-setting-schema "invalid SettingSchema"
        name type default scopes parser validator materialize))
    (%make-setting-schema
      name type default (copy-list scopes) parser validator materialize))

  (define (setting-schema-valid? schema value)
    (unless (setting-schema? schema)
      (assertion-violation
        'setting-schema-valid? "expected a SettingSchema" schema))
    (and (type-valid? (setting-schema-type schema) value)
         (let ([validator (setting-schema-validator schema)])
           (or (not validator) (and (validator value) #t)))))

  (define-condition-type &setting-error &condition
    make-setting-error setting-error?
    (name setting-error-name)
    (source setting-error-source)
    (input setting-error-input)
    (reason setting-error-reason))

  (define-record-type
    (setting-value %make-setting-value setting-value?)
    (fields
      (immutable schema setting-value-schema)
      (immutable name setting-value-name)
      (immutable value setting-value-value)
      (immutable scope setting-value-scope)
      (immutable source setting-value-source)))

  (define (raise-setting-error schema source input reason)
    (raise
      (condition
        (make-setting-error
          (setting-schema-name schema) source input reason)
        (make-message-condition "invalid setting value"))))

  (define (make-setting-value schema input scope source)
    (unless (and (setting-schema? schema)
                 (memq scope (setting-schema-scopes schema))
                 (or (not source) (location? source)))
      (assertion-violation
        'make-setting-value "invalid SettingValue context"
        schema scope source))
    (let ([value
           (guard
             (condition
               [else (raise-setting-error schema source input condition)])
             (let ([parser (setting-schema-parser schema)])
               (if parser (parser input) input)))])
      (unless (setting-schema-valid? schema value)
        (raise-setting-error schema source input 'validation))
      (%make-setting-value
        schema (setting-schema-name schema) value scope source)))

  (define (setting-value-extension value)
    (unless (setting-value? value)
      (assertion-violation
        'setting-value-extension "expected a SettingValue" value))
    ((setting-schema-materialize (setting-value-schema value))
     (setting-value-value value)
     (setting-value-scope value)))

  (define (delete-duplicates values)
    (let loop ([remaining values] [seen '()] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(memq (car remaining) seen)
         (loop (cdr remaining) seen result)]
        [else
         (loop (cdr remaining)
               (cons (car remaining) seen)
               (cons (car remaining) result))])))
)
