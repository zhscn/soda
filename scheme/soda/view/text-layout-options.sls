(library (soda view text-layout-options)
  (export make-text-layout-options text-layout-options?
          text-layout-options-tab-width text-layout-options-wrap?
          default-text-layout-options text-layout-options-facet
          make-tab-width-setting-extension make-soft-wrap-setting-extension
          line-number-facet line-number-compartment line-numbers-enabled?
          make-line-number-extension make-line-number-setting-extension
          guide-column-facet guide-column-compartment guide-column
          make-guide-column-extension constant-position-facet
          constant-position-compartment constant-position-enabled?
          make-constant-position-extension)
  (import (rnrs)
          (soda kernel extension))

  (define-record-type
    (text-layout-options %make-text-layout-options text-layout-options?)
    (fields tab-width wrap?))

  (define (make-text-layout-options tab-width wrap?)
    (unless (and (integer? tab-width) (exact? tab-width)
                 (> tab-width 0) (boolean? wrap?))
      (assertion-violation
        'make-text-layout-options "invalid text layout options" tab-width wrap?))
    (%make-text-layout-options tab-width wrap?))

  (define default-text-layout-options (make-text-layout-options 8 #t))

  (define-record-type text-layout-option-contribution
    (fields tab-width wrap?))

  (define (combine-text-layout-options values)
    (let loop ([remaining values] [tab-width #f] [wrap? 'unset])
      (if (null? remaining)
          (make-text-layout-options
            (or tab-width
                (text-layout-options-tab-width default-text-layout-options))
            (if (eq? wrap? 'unset)
                (text-layout-options-wrap? default-text-layout-options)
                wrap?))
          (let ([value (car remaining)])
            (cond
              [(text-layout-options? value)
               (loop (cdr remaining)
                     (or tab-width (text-layout-options-tab-width value))
                     (if (eq? wrap? 'unset)
                         (text-layout-options-wrap? value) wrap?))]
              [(text-layout-option-contribution? value)
               (loop
                 (cdr remaining)
                 (or tab-width
                     (text-layout-option-contribution-tab-width value))
                 (if (and (eq? wrap? 'unset)
                          (boolean? (text-layout-option-contribution-wrap? value)))
                     (text-layout-option-contribution-wrap? value)
                     wrap?))]
              [else
               (assertion-violation
                 'text-layout-options
                 "invalid text layout option contribution" value)])))))

  (define text-layout-options-facet
    (make-facet 'text-layout-options 'view default-text-layout-options
                combine-text-layout-options equal? equal?))

  (define (make-tab-width-setting-extension width)
    (unless (and (integer? width) (exact? width) (> width 0))
      (assertion-violation
        'make-tab-width-setting-extension "expected a positive tab width" width))
    (make-facet-provider
      text-layout-options-facet
      (make-text-layout-option-contribution width 'unset)))

  (define (make-soft-wrap-setting-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation
        'make-soft-wrap-setting-extension "expected a soft-wrap boolean" enabled?))
    (make-facet-provider
      text-layout-options-facet
      (make-text-layout-option-contribution #f enabled?)))

  (define (first-option values default)
    (if (null? values) default (car values)))

  (define line-number-facet
    (make-facet 'line-numbers 'view #f
                (lambda (values) (first-option values #f)) eq? eq?))
  (define line-number-compartment (make-compartment 'line-numbers 'view))
  (define (line-numbers-enabled? configuration)
    (configuration-facet configuration line-number-facet 'view))
  (define (make-line-number-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-line-number-extension "expected a boolean" enabled?))
    (make-facet-provider line-number-facet enabled? 'highest))
  (define (make-line-number-setting-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation
        'make-line-number-setting-extension "expected a boolean" enabled?))
    (make-facet-provider line-number-facet enabled?))

  (define guide-column-facet
    (make-facet 'guide-column 'view #f
                (lambda (values) (first-option values #f)) equal? equal?))
  (define guide-column-compartment (make-compartment 'guide-column 'view))
  (define (guide-column configuration)
    (configuration-facet configuration guide-column-facet 'view))
  (define (make-guide-column-extension column)
    (unless (or (not column)
                (and (integer? column) (exact? column) (> column 0)))
      (assertion-violation
        'make-guide-column-extension "expected #f or a positive guide column" column))
    (make-facet-provider guide-column-facet column))

  (define constant-position-facet
    (make-facet 'constant-position 'view #f
                (lambda (values) (first-option values #f)) eq? eq?))
  (define constant-position-compartment
    (make-compartment 'constant-position 'view))
  (define (constant-position-enabled? configuration)
    (configuration-facet configuration constant-position-facet 'view))
  (define (make-constant-position-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation
        'make-constant-position-extension "expected a boolean" enabled?))
    (make-facet-provider constant-position-facet enabled?))
)
