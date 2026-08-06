(library (soda packages base editing-options)
  (export auto-indent-facet
          auto-indent-compartment
          auto-indent-enabled?
          make-auto-indent-extension
          indent-options?
          make-indent-options
          indent-options-width
          indent-options-insert-tabs?
          default-indent-options
          indent-options-facet
          indent-options-compartment
          configuration-indent-options
          make-indent-options-extension
          layout-options-compartment
          make-layout-options-extension)
  (import (rnrs)
          (soda kernel extension)
          (soda view text-layout))

  ;; Options remain ordinary configuration contributions.  These stable
  ;; compartments let a command, mode, or user configuration replace just one
  ;; option group without owning a mutable global settings table.
  (define (first-option values default)
    (if (null? values) default (car values)))

  (define auto-indent-facet
    (make-facet 'auto-indent 'buffer #t
                (lambda (values) (first-option values #t))
                eq? eq?))

  (define auto-indent-compartment (make-compartment 'auto-indent 'buffer))

  (define (make-auto-indent-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-auto-indent-extension
                           "expected an auto-indent boolean" enabled?))
    (make-facet-provider auto-indent-facet enabled?))

  (define (auto-indent-enabled? configuration)
    (configuration-facet configuration auto-indent-facet 'buffer))

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

  (define indent-options-facet
    (make-facet 'indent-options 'buffer default-indent-options
                (lambda (values) (first-option values default-indent-options))
                eq? eq?))

  (define indent-options-compartment (make-compartment 'indent-options 'buffer))

  (define (configuration-indent-options configuration)
    (configuration-facet configuration indent-options-facet 'buffer))

  (define (make-indent-options-extension width insert-tabs?)
    (make-facet-provider
      indent-options-facet (make-indent-options width insert-tabs?)))

  (define layout-options-compartment
    (make-compartment 'text-layout-options 'view))

  (define (make-layout-options-extension tab-width wrap?)
    (make-facet-provider
      text-layout-options-facet
      (make-text-layout-options tab-width wrap?)))
)
