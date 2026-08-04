(library (soda host window)
  (export window?
          window-id
          window-kind
          window-view-id
          window-axis
          window-children
          window-weights
          window-rectangle
          window-selected?
          window-leaves)
  (import
    (except (soda host internal window)
            make-leaf-window
            make-split-window
            window-layout!
            window-set-selected!))
)
