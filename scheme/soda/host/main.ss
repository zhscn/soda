#!chezscheme
(import (chezscheme)
        (soda bootstrap))

(scheme-start
 (lambda arguments
  (let ([application (make-soda-application)])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (soda-application-run! application)
        0)
      (lambda ()
        (soda-application-close! application))))))
