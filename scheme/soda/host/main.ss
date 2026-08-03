#!chezscheme
(import (chezscheme)
        (soda host state))

(scheme-start
  (lambda arguments
    (let ([state (make-host-state)])
      (host-state-close! state)
      0)))
