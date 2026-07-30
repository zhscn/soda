(library (soda native)
  (export load-soda-native-library!)
  (import (chezscheme))

  (define loaded-paths (make-hashtable string-hash string=?))

  (define (load-soda-native-library! environment-variable)
    (let ([path
            (and
              (not
                (foreign-entry?
                  "soda_embedded_native"))
              (getenv environment-variable))])
      (when
        (and path
             (not (hashtable-contains? loaded-paths path)))
        (load-shared-object path)
        (hashtable-set! loaded-paths path #t)))))
