#!chezscheme
(import (chezscheme)
        (soda editor tui))

(scheme-start
  (lambda arguments
    (run-tui-editor
      (and (pair? arguments) (car arguments)))
    0))
