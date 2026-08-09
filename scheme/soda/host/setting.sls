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
          make-default-setting-value
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
          setting-error-reason
          make-setting-declaration
          setting-declaration?
          setting-declaration-name
          setting-declaration-input
          setting-declaration-scope
          setting-declaration-source
          make-configuration-source
          configuration-source?
          configuration-source-id
          configuration-source-layer
          configuration-source-target
          configuration-source-declarations
          configuration-source-generation
          make-configuration-context
          configuration-context?
          configuration-context-workspace
          configuration-context-resource
          make-resolved-setting
          resolved-setting?
          resolved-setting-value
          resolved-setting-source-id
          resolved-setting-layer)
  (import (rnrs)
          (soda kernel location)
          (soda kernel resource))

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

  (define (make-default-setting-value schema scope)
    (unless (and (setting-schema? schema)
                 (memq scope (setting-schema-scopes schema)))
      (assertion-violation
        'make-default-setting-value "invalid default setting scope"
        schema scope))
    (%make-setting-value
      schema (setting-schema-name schema)
      (setting-schema-default schema) scope #f))

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

  (define-record-type
    (setting-declaration %make-setting-declaration setting-declaration?)
    (fields name input scope source))

  (define (make-setting-declaration name input scope source)
    (unless (and (symbol? name) (memq scope valid-scopes)
                 (or (not source) (location? source)))
      (assertion-violation
        'make-setting-declaration "invalid setting declaration"
        name scope source))
    (%make-setting-declaration name input scope source))

  (define configuration-layers '(application user workspace file-local))

  (define-record-type
    (configuration-source %make-configuration-source configuration-source?)
    (fields id layer target declarations generation))

  (define (make-configuration-source id layer target declarations generation)
    (unless (and (symbol? id) (memq layer configuration-layers)
                 (list? declarations)
                 (for-all setting-declaration? declarations)
                 (integer? generation) (exact? generation) (>= generation 0)
                 (case layer
                   [(application user) (not target)]
                   [(workspace) (and target #t)]
                   [(file-local) (resource? target)]))
      (assertion-violation
        'make-configuration-source "invalid ConfigurationSource"
        id layer target declarations generation))
    (%make-configuration-source
      id layer target (copy-list declarations) generation))

  (define-record-type
    (configuration-context %make-configuration-context configuration-context?)
    (fields workspace resource))

  (define (make-configuration-context workspace resource)
    (unless (or (not resource) (resource? resource))
      (assertion-violation
        'make-configuration-context "invalid configuration Resource" resource))
    (%make-configuration-context workspace resource))

  (define-record-type
    (resolved-setting %make-resolved-setting resolved-setting?)
    (fields value source-id layer))

  (define (make-resolved-setting value source-id layer)
    (unless (and (setting-value? value)
                 (or (not source-id) (symbol? source-id))
                 (or (not layer) (memq layer configuration-layers)))
      (assertion-violation
        'make-resolved-setting "invalid ResolvedSetting"
        value source-id layer))
    (%make-resolved-setting value source-id layer))
)
