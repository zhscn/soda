(library (soda ffi helpers)
  (export native-null-pointer?
          make-native-error
          make-native-status-checker)
  (import (chezscheme))

  ;; Native entry points are registered by the C launcher before the Chez
  ;; heap is built.  This library only contains common ABI helpers; it does
  ;; not load shared objects or inspect environment variables.
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
)
