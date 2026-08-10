(library (soda packages search-options)
  (export search-case-sensitive?
          search-whole-word?
          search-regular-expression?
          search-case-sensitive-compartment
          search-whole-word-compartment
          search-regular-expression-compartment
          make-search-case-sensitive-extension
          make-search-whole-word-extension
          make-search-regular-expression-extension)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel view-state)
          (soda host command))

  (define (first-value values default)
    (if (null? values) default (car values)))

  (define search-case-sensitive-facet
    (make-facet 'search-case-sensitive 'view #t
                (lambda (values) (first-value values #t)) eq? eq?))
  (define search-case-sensitive-compartment
    (make-compartment 'search-case-sensitive 'view))

  (define search-whole-word-facet
    (make-facet 'search-whole-word 'view #f
                (lambda (values) (first-value values #f)) eq? eq?))
  (define search-whole-word-compartment
    (make-compartment 'search-whole-word 'view))

  (define search-regular-expression-facet
    (make-facet 'search-regular-expression 'view #f
                (lambda (values) (first-value values #f)) eq? eq?))
  (define search-regular-expression-compartment
    (make-compartment 'search-regular-expression 'view))

  (define (context-option context facet)
    (configuration-facet
      (view-state-configuration (command-context-view-state context)) facet 'view))

  (define (search-case-sensitive? context)
    (context-option context search-case-sensitive-facet))

  (define (search-whole-word? context)
    (context-option context search-whole-word-facet))

  (define (search-regular-expression? context)
    (context-option context search-regular-expression-facet))

  (define (boolean-extension who facet value)
    (unless (boolean? value)
      (assertion-violation who "expected a boolean" value))
    (make-facet-provider facet value))

  (define (make-search-case-sensitive-extension value)
    (boolean-extension
      'make-search-case-sensitive-extension search-case-sensitive-facet value))

  (define (make-search-whole-word-extension value)
    (boolean-extension
      'make-search-whole-word-extension search-whole-word-facet value))

  (define (make-search-regular-expression-extension value)
    (boolean-extension
      'make-search-regular-expression-extension search-regular-expression-facet value))
)
