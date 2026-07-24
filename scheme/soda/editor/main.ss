#!r6rs
(import (rnrs)
        (rnrs programs)
        (soda editor tui))

(define arguments (cdr (command-line)))
(run-tui-editor (and (pair? arguments) (car arguments)))
