(library (soda packages base editing-options)
  (export auto-indent-facet
          auto-indent-compartment
          auto-indent-enabled?
          make-auto-indent-extension
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

  (define layout-options-compartment
    (make-compartment 'text-layout-options 'view))

  (define (make-layout-options-extension tab-width wrap?)
    (make-facet-provider
      text-layout-options-facet
      (make-text-layout-options tab-width wrap?)))
)
