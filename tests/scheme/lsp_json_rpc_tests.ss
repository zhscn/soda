#!r6rs
(import (rnrs)
        (soda json)
        (soda editor lsp-json-rpc))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'lsp-json-rpc-tests message irritants)))

(define first
  (make-json-object
    (list (cons "jsonrpc" "2.0")
          (cons "id" 1)
          (cons "method" "initialize"))))
(define second
  (make-json-object
    (list (cons "jsonrpc" "2.0")
          (cons "method" "initialized")
          (cons "params" (make-json-object '())))))
(define first-frame (lsp-json-rpc-frame first))
(define second-frame (lsp-json-rpc-frame second))
(define joined
  (let* ([left-length (bytevector-length first-frame)]
         [right-length (bytevector-length second-frame)]
         [result (make-bytevector (+ left-length right-length))])
    (bytevector-copy! first-frame 0 result 0 left-length)
    (bytevector-copy! second-frame 0 result left-length right-length)
    result))

(define decoder (make-lsp-json-rpc-decoder))
(define split (- (bytevector-length first-frame) 3))
(check
  (null?
    (lsp-json-rpc-decode!
      decoder
      (let ([result (make-bytevector split)])
        (bytevector-copy! joined 0 result 0 split)
        result)))
  "partial LSP frame must not produce a message")
(check
  (positive? (lsp-json-rpc-decoder-pending-bytes decoder))
  "partial LSP frame was not retained")
(define decoded
  (lsp-json-rpc-decode!
    decoder
    (let* ([length (- (bytevector-length joined) split)]
           [result (make-bytevector length)])
      (bytevector-copy! joined split result 0 length)
      result)))
(check
  (and
    (= (length decoded) 2)
    (= (json-object-ref (car decoded) "id" #f) 1)
    (string=? (json-object-ref (cadr decoded) "method" #f) "initialized")
    (zero? (lsp-json-rpc-decoder-pending-bytes decoder)))
  "fragmented and coalesced LSP frames did not decode in order")

(let ([failed? #f])
  (guard (condition [else (set! failed? #t)])
    (lsp-json-rpc-decode!
      (make-lsp-json-rpc-decoder)
      (string->utf8 "Content-Length: x\r\n\r\n{}")))
  (check failed? "invalid Content-Length was accepted"))

(display "lsp json-rpc tests passed\n")
