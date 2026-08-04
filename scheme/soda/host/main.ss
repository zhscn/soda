#!chezscheme
(import (chezscheme)
        (soda host internal state))

(scheme-start
  (lambda arguments
    (let ([state (make-host-state)])
      (host-state-run! state)
      (host-state-close! state)
      0)))
