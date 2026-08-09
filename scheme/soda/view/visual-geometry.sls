(library (soda view visual-geometry)
  (export text-layout? text-layout-frame text-layout-display-map
          text-layout-cursor-row text-layout-cursor-column text-layout-complete?
          text-layout-visible-ranges text-layout-content-height
          text-layout-document->point text-layout-point->document
          text-layout-point->display-entry text-layout-vertical-target
          make-visual-position visual-position? visual-position-offset
          visual-position-line visual-position-row visual-position-column
          text-layout-document-visual-position text-layout-visual-position-at
          text-layout-visual-step text-layout-scroll-start
          text-layout-page-start text-layout-recenter-start
          text-layout-viewport-row-position text-layout-reveal-viewport)
  (import (soda view text-layout internal)))
