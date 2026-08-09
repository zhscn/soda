(library (soda packages base fundamental-editing)
  (export make-fundamental-editing! fundamental-editing?
          fundamental-editing-keymap fundamental-mode
          fundamental-fallback-input-layer fundamental-input-disposition)
  (import (soda packages base fundamental-editing internal)))
