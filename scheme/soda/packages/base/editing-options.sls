(library (soda packages base editing-options)
  (export auto-indent-option
          auto-indent-facet
          auto-indent-compartment
          auto-indent-enabled?
          make-auto-indent-extension
          make-auto-indent-setting-extension
          indent-options-option
          indent-options?
          make-indent-options
          indent-options-width
          indent-options-insert-tabs?
          default-indent-options
          indent-options-facet
          indent-options-compartment
          configuration-indent-options
          make-indent-options-extension
          make-indent-width-setting-extension
          make-tab-to-spaces-setting-extension
          fill-options-option
          fill-options?
          make-fill-options
          fill-options-column
          fill-options-auto-fill?
          default-fill-options
          fill-options-facet
          fill-options-compartment
          configuration-fill-options
          make-fill-options-extension
          make-fill-column-setting-extension
          make-auto-fill-setting-extension
          layout-options-compartment
          make-layout-options-extension)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel option)
          (soda view text-layout-options))

  ;; Options remain ordinary configuration contributions.  These stable
  ;; compartments let a command, mode, or user configuration replace just one
  ;; option group without owning a mutable global settings table.
  (define auto-indent-option
    (make-option-spec
      'auto-indent #t boolean? eq?
      "Whether newline commands preserve leading indentation."))
  (define auto-indent-facet (option-spec-facet auto-indent-option))
  (define auto-indent-compartment (option-spec-compartment auto-indent-option))

  (define (make-auto-indent-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-auto-indent-extension
                           "expected an auto-indent boolean" enabled?))
    (make-buffer-local-option-extension auto-indent-option enabled?))

  (define (make-auto-indent-setting-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-auto-indent-setting-extension
                           "expected an auto-indent boolean" enabled?))
    (make-facet-provider auto-indent-facet enabled?))

  (define (auto-indent-enabled? configuration)
    (option-ref configuration auto-indent-option))

  ;; Indent insertion is a Buffer policy because it changes Document text.
  ;; Its width is intentionally separate from View-local tab rendering: two
  ;; Views may display a tab differently without creating different content.
  (define-record-type
    (indent-options %make-indent-options indent-options?)
    (fields (immutable width indent-options-width)
            (immutable insert-tabs? indent-options-insert-tabs?)))

  (define (make-indent-options width insert-tabs?)
    (unless (and (integer? width) (exact? width) (> width 0)
                 (boolean? insert-tabs?))
      (assertion-violation 'make-indent-options
                           "expected a positive width and tab insertion flag"
                           width insert-tabs?))
    (%make-indent-options width insert-tabs?))

  (define default-indent-options (make-indent-options 4 #t))

  (define-record-type indent-option-contribution
    (fields width insert-tabs?))

  (define (combine-indent-options values)
    (let loop ([remaining values] [width #f] [insert-tabs? 'unset])
      (if (null? remaining)
          (make-indent-options
            (or width (indent-options-width default-indent-options))
            (if (eq? insert-tabs? 'unset)
                (indent-options-insert-tabs? default-indent-options)
                insert-tabs?))
          (let ([value (car remaining)])
            (cond
              [(indent-options? value)
               (loop (cdr remaining)
                     (or width (indent-options-width value))
                     (if (eq? insert-tabs? 'unset)
                         (indent-options-insert-tabs? value)
                         insert-tabs?))]
              [(indent-option-contribution? value)
               (loop (cdr remaining)
                     (or width (indent-option-contribution-width value))
                     (if (and (eq? insert-tabs? 'unset)
                              (boolean?
                                (indent-option-contribution-insert-tabs? value)))
                         (indent-option-contribution-insert-tabs? value)
                         insert-tabs?))]
              [else
               (assertion-violation
                 'indent-options "invalid indentation option contribution" value)])))))

  (define indent-options-option
    (make-option-spec
      'indent-options default-indent-options indent-options? eq?
      combine-indent-options
      "Indentation width and tab insertion policy for the Buffer."))
  (define indent-options-facet (option-spec-facet indent-options-option))
  (define indent-options-compartment (option-spec-compartment indent-options-option))

  (define (configuration-indent-options configuration)
    (option-ref configuration indent-options-option))

  (define (make-indent-options-extension width insert-tabs?)
    (make-buffer-local-option-extension
      indent-options-option (make-indent-options width insert-tabs?)))

  (define (make-indent-width-setting-extension width)
    (unless (and (integer? width) (exact? width) (> width 0))
      (assertion-violation 'make-indent-width-setting-extension
                           "expected a positive indentation width" width))
    (make-facet-provider
      indent-options-facet (make-indent-option-contribution width 'unset)))

  (define (make-tab-to-spaces-setting-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-tab-to-spaces-setting-extension
                           "expected a tab-to-spaces boolean" enabled?))
    (make-facet-provider
      indent-options-facet
      (make-indent-option-contribution #f (not enabled?))))

  ;; Paragraph fill and automatic hard wrap share one Buffer-local text
  ;; policy.  It describes source text rather than terminal geometry, so two
  ;; Views may render the same line at different widths without changing when
  ;; an edit wraps it.
  (define-record-type
    (fill-options %make-fill-options fill-options?)
    (fields (immutable column fill-options-column)
            (immutable auto-fill? fill-options-auto-fill?)))

  (define (make-fill-options column auto-fill?)
    (unless (and (integer? column) (exact? column) (> column 0)
                 (boolean? auto-fill?))
      (assertion-violation 'make-fill-options
                           "expected a positive fill column and boolean auto-fill policy"
                           column auto-fill?))
    (%make-fill-options column auto-fill?))

  (define default-fill-options (make-fill-options 80 #f))

  (define-record-type fill-option-contribution
    (fields column auto-fill?))

  (define (combine-fill-options values)
    (let loop ([remaining values] [column #f] [auto-fill? 'unset])
      (if (null? remaining)
          (make-fill-options
            (or column (fill-options-column default-fill-options))
            (if (eq? auto-fill? 'unset)
                (fill-options-auto-fill? default-fill-options)
                auto-fill?))
          (let ([value (car remaining)])
            (cond
              [(fill-options? value)
               (loop (cdr remaining)
                     (or column (fill-options-column value))
                     (if (eq? auto-fill? 'unset)
                         (fill-options-auto-fill? value)
                         auto-fill?))]
              [(fill-option-contribution? value)
               (loop (cdr remaining)
                     (or column (fill-option-contribution-column value))
                     (if (and (eq? auto-fill? 'unset)
                              (boolean?
                                (fill-option-contribution-auto-fill? value)))
                         (fill-option-contribution-auto-fill? value)
                         auto-fill?))]
              [else
               (assertion-violation
                 'fill-options "invalid fill option contribution" value)])))))

  (define fill-options-option
    (make-option-spec
      'fill-options default-fill-options fill-options? eq?
      combine-fill-options
      "Paragraph fill column and automatic hard-wrapping policy."))
  (define fill-options-facet (option-spec-facet fill-options-option))
  (define fill-options-compartment (option-spec-compartment fill-options-option))

  (define (configuration-fill-options configuration)
    (option-ref configuration fill-options-option))

  (define (make-fill-options-extension column auto-fill?)
    (make-buffer-local-option-extension
      fill-options-option (make-fill-options column auto-fill?)))

  (define (make-fill-column-setting-extension column)
    (unless (and (integer? column) (exact? column) (> column 0))
      (assertion-violation 'make-fill-column-setting-extension
                           "expected a positive fill column" column))
    (make-facet-provider
      fill-options-facet (make-fill-option-contribution column 'unset)))

  (define (make-auto-fill-setting-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-auto-fill-setting-extension
                           "expected an auto-fill boolean" enabled?))
    (make-facet-provider
      fill-options-facet (make-fill-option-contribution #f enabled?)))

  (define layout-options-compartment
    (make-compartment 'text-layout-options 'view))

  (define (make-layout-options-extension tab-width wrap?)
    (make-facet-provider
      text-layout-options-facet
      (make-text-layout-options tab-width wrap?)
      'highest))
)
