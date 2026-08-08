(library (soda packages base editing-options)
  (export auto-indent-option
          auto-indent-facet
          auto-indent-compartment
          auto-indent-enabled?
          make-auto-indent-extension
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
          layout-options-compartment
          make-layout-options-extension)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel option)
          (soda view text-layout))

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

  (define indent-options-option
    (make-option-spec
      'indent-options default-indent-options indent-options? eq?
      "Indentation width and tab insertion policy for the Buffer."))
  (define indent-options-facet (option-spec-facet indent-options-option))
  (define indent-options-compartment (option-spec-compartment indent-options-option))

  (define (configuration-indent-options configuration)
    (option-ref configuration indent-options-option))

  (define (make-indent-options-extension width insert-tabs?)
    (make-buffer-local-option-extension
      indent-options-option (make-indent-options width insert-tabs?)))

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

  (define fill-options-option
    (make-option-spec
      'fill-options default-fill-options fill-options? eq?
      "Paragraph fill column and automatic hard-wrapping policy."))
  (define fill-options-facet (option-spec-facet fill-options-option))
  (define fill-options-compartment (option-spec-compartment fill-options-option))

  (define (configuration-fill-options configuration)
    (option-ref configuration fill-options-option))

  (define (make-fill-options-extension column auto-fill?)
    (make-buffer-local-option-extension
      fill-options-option (make-fill-options column auto-fill?)))

  (define layout-options-compartment
    (make-compartment 'text-layout-options 'view))

  (define (make-layout-options-extension tab-width wrap?)
    (make-facet-provider
      text-layout-options-facet
      (make-text-layout-options tab-width wrap?)))
)
