(library (soda view text-layout)
  (export make-text-layout text-layout? text-layout-frame text-layout-display-map
          text-layout-cursor-row text-layout-cursor-column text-layout-complete?
          text-layout-visible-ranges text-layout-content-height
          text-layout-document->point text-layout-point->document
          text-layout-point->display-entry text-layout-vertical-target
          make-visual-position visual-position? visual-position-offset
          visual-position-line visual-position-row visual-position-column
          text-layout-document-visual-position text-layout-visual-position-at
          text-layout-visual-step text-layout-scroll-start text-layout-page-start
          text-layout-recenter-start text-layout-viewport-row-position
          text-layout-reveal-viewport make-text-layout-options text-layout-options?
          text-layout-options-tab-width text-layout-options-wrap?
          default-text-layout-options text-layout-options-facet
          make-tab-width-setting-extension make-soft-wrap-setting-extension
          line-number-facet line-number-compartment line-numbers-enabled?
          make-line-number-extension make-line-number-setting-extension
          guide-column-facet guide-column-compartment guide-column
          make-guide-column-extension constant-position-facet
          constant-position-compartment constant-position-enabled?
          make-constant-position-extension snapshot-display-stream
          layout-snapshot-display-stream layout-display-stream layout-text-snapshot)
  (import (soda view text-layout internal)))
