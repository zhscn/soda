(library (soda kernel transaction)
  (export make-text-change
          text-change?
          text-change-from
          text-change-to
          text-change-insert
          text-change-insert-length
          make-change-set
          change-set?
          change-set-old-length
          change-set-new-length
          change-set-changes
          change-set-empty?
          change-set-apply
          change-set-invert
          change-set-compose
          make-change-desc
          change-desc?
          change-desc-old-length
          change-desc-new-length
          change-desc-changes
          change-set-change-desc
          change-desc-map-offset
          change-desc-map-range
          change-set-map-offset
          change-set-map-range)
  (import (soda kernel change)))
