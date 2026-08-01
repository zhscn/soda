#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor lsp-position)
        (soda editor lsp-protocol))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'lsp-position-tests message irritants)))

(define text "a😀\n猫z\n")
(define document (make-document text 43001))
(define buffer (make-buffer 43002 document "*lsp-position*" 'fundamental-mode))
(define emoji-offset (bytevector-length (string->utf8 "a")))
(define cat-offset (bytevector-length (string->utf8 "a😀\n")))

(define emoji-position (lsp-buffer-position-at buffer emoji-offset))
(check
  (and
    (= (lsp-position-line emoji-position) 0)
    (= (lsp-position-character emoji-position) 1)
    (= (lsp-buffer-offset-at buffer (make-lsp-position 0 3))
       (+ emoji-offset (bytevector-length (string->utf8 "😀"))))
    (not (lsp-buffer-offset-at buffer (make-lsp-position 0 2)))
    (= (lsp-buffer-offset-at buffer (make-lsp-position 1 0)) cat-offset)
    (= (lsp-position-line (lsp-buffer-position-at buffer cat-offset)) 1))
  "LSP UTF-16 position conversion did not preserve Unicode boundaries")

(buffer-close! buffer)
(display "lsp position tests passed\n")
