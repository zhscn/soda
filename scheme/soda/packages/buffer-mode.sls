(library (soda packages buffer-mode)
  (export make-mode-spec mode-spec? mode-spec-id mode-spec-kind
          mode-spec-display-name mode-spec-parent mode-spec-extensions
          mode-spec-command-categories mode-spec-modeline-contribution
          buffer-mode-facet buffer-minor-modes-facet
          buffer-major-mode-compartment buffer-minor-modes-compartment
          buffer-input-layers-facet buffer-display-profile-facet
          buffer-update-listeners-facet make-buffer-mode-extension
          make-buffer-modes-extension set-buffer-major-mode-effect
          set-buffer-minor-modes-effect make-buffer-input-layer-extension
          buffer-input-context make-buffer-display-profile-extension)
  (import (soda packages buffer-ui internal)))
