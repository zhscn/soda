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
  (import (soda view text-layout internal)))
