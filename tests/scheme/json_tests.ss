#!r6rs
(import (rnrs)
        (soda json))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'json-tests message irritants)))

(define decoded
  (json-parse
    "{\"method\":\"workspace/configuration\",\"params\":[true,false,null,12,-1.5e2,\"\\uD83D\\uDE00\"]}"))

(check
  (and
    (json-object? decoded)
    (string=?
      (json-object-ref decoded "method" #f)
      "workspace/configuration")
    (let ([values (json-array-values (json-object-ref decoded "params" #f))])
      (let* ([second (cdr values)]
             [third (cdr second)]
             [fourth (cdr third)]
             [fifth (cdr fourth)]
             [sixth (cdr fifth)])
        (and
          (eq? (car values) #t)
          (eq? (car second) #f)
          (json-null? (car third))
          (= (car fourth) 12)
          (= (car fifth) -150.0)
          (string=? (car sixth) "😀")))))
  "JSON parser did not decode LSP-compatible values")

(define round-trip
  (json-parse-bytevector (json-write-bytevector decoded)))
(check
  (and
    (string=? (json-object-ref round-trip "method" #f)
              "workspace/configuration")
    (equal?
      (json-array-values (json-object-ref round-trip "params" #f))
      (json-array-values (json-object-ref decoded "params" #f))))
  "JSON writer did not preserve the decoded protocol value")

(let ([failed? #f])
  (guard (condition [else (set! failed? #t)])
    (json-parse "{\"unterminated\": [1,}"))
  (check failed? "JSON parser accepted malformed input"))

(display "json tests passed\n")
