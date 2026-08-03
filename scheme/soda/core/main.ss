#!chezscheme
(import (chezscheme)
        (soda core state))

(scheme-start
  (lambda arguments
    (let ([state (make-core-state)])
      (core-state-close! state)
      0)))
