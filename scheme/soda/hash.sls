(library (soda hash)
  (export fnv1a64-offset-basis
          fnv1a64-byte
          fnv1a64-bytevector
          fnv1a64-string)
  (import (rnrs))

  ;; FNV-1a is kept as a streaming update API so callers can mix path
  ;; separators, delimiters, and file contents without allocating a combined
  ;; bytevector.
  (define fnv1a64-offset-basis 14695981039346656037)
  (define fnv1a64-prime 1099511628211)
  (define fnv1a64-mask #xffffffffffffffff)

  (define (fnv1a64-byte hash byte)
    (bitwise-and
      (* (bitwise-xor hash byte) fnv1a64-prime)
      fnv1a64-mask))

  (define (fnv1a64-bytevector hash bytes)
    (let loop ([position 0] [hash hash])
      (if
        (= position (bytevector-length bytes))
        hash
        (loop
          (+ position 1)
          (fnv1a64-byte
            hash
            (bytevector-u8-ref bytes position))))))

  (define (fnv1a64-string hash value)
    (fnv1a64-bytevector hash (string->utf8 value)))
)
