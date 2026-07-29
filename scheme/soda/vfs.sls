(library (soda vfs)
  (export vfs-entry?
          vfs-entry-name
          vfs-entry-kind
          decode-vfs-directory-entries)
  (import (rnrs))

  (define-record-type vfs-entry
    (fields name kind))

  (define (directory-entry-kind value)
    (case value
      [(1) 'file]
      [(2) 'directory]
      [(3) 'link]
      [(4) 'fifo]
      [(5) 'socket]
      [(6) 'character-device]
      [(7) 'block-device]
      [else 'unknown]))

  (define (bytevector-u32-little-endian bytes offset)
    (+
      (bytevector-u8-ref bytes offset)
      (bitwise-arithmetic-shift-left
        (bytevector-u8-ref bytes (+ offset 1))
        8)
      (bitwise-arithmetic-shift-left
        (bytevector-u8-ref bytes (+ offset 2))
        16)
      (bitwise-arithmetic-shift-left
        (bytevector-u8-ref bytes (+ offset 3))
        24)))

  (define (decode-vfs-directory-entries bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        'decode-vfs-directory-entries
        "expected a bytevector"
        bytes))
    (let ([size (bytevector-length bytes)])
      (let loop ([offset 0] [entries '()])
        (cond
          [(= offset size) (reverse entries)]
          [(> (+ offset 5) size)
           (assertion-violation
             'decode-vfs-directory-entries
             "truncated directory entry header"
             offset
             size)]
          [else
           (let* ([kind
                    (directory-entry-kind
                      (bytevector-u8-ref bytes offset))]
                  [name-size
                    (bytevector-u32-little-endian
                      bytes
                      (+ offset 1))]
                  [name-start (+ offset 5)]
                  [name-end (+ name-start name-size)])
             (when (> name-end size)
               (assertion-violation
                 'decode-vfs-directory-entries
                 "truncated directory entry name"
                 offset
                 name-size
                 size))
             (let ([name-bytes (make-bytevector name-size)])
               (bytevector-copy!
                 bytes
                 name-start
                 name-bytes
                 0
                 name-size)
               (loop
                 name-end
                 (cons
                   (make-vfs-entry
                     (utf8->string name-bytes)
                     kind)
                   entries))))])))))
