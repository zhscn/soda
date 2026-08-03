(library (soda native)
  (export load-soda-native-library!
          native-null-pointer?
          make-native-error
          make-native-status-checker)
  (import (chezscheme))

  (define loaded-paths (make-hashtable string-hash string=?))

  (define (native-null-pointer? pointer)
    (or (not pointer)
        (and (integer? pointer) (zero? pointer))))

  (define (make-native-error last-error)
    (lambda (who)
      (error who (last-error))))

  (define (make-native-status-checker native-error)
    (lambda (who status)
      (when (negative? status)
        (native-error who))))

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
