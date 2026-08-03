(library (soda editor filesystem)
  (export ensure-directory!)
  (import (chezscheme))

  (define (ensure-directory! directory)
    (unless
      (or (string=? directory "")
          (string=? directory ".")
          (string=? directory "/")
          (file-directory? directory))
      (let ([parent (path-parent directory)])
        (unless (string=? parent directory)
          (ensure-directory! parent)))
      (mkdir directory))))
