(library (soda support vfs)
  (export vfs-entry?
          vfs-entry-name
          vfs-entry-kind
          decode-vfs-directory-entries
          vfs-path-separator?
          vfs-directory-path
          vfs-normalize-path
          vfs-resolve-path
          vfs-parent-directory
          vfs-path-field-boundaries
          vfs-completion-directory
          vfs-path-join
          vfs-stat?
          vfs-stat-kind
          vfs-stat-size
          vfs-stat-mtime-seconds
          vfs-stat-mtime-nanoseconds
          vfs-stat-device
          vfs-stat-inode
          vfs-stat-same-version?
          decode-vfs-stat)
  (import (rnrs)
          (only (chezscheme)
                current-directory
                directory-separator
                getenv
                path-absolute?
                path-build
                path-parent))

  (define-record-type vfs-entry
    (fields name kind))

  (define-record-type vfs-stat
    (fields kind size mtime-seconds mtime-nanoseconds device inode))

  (define (vfs-entry-kind-code value)
    (case value
      [(1) 'file]
      [(2) 'directory]
      [(3) 'link]
      [(4) 'fifo]
      [(5) 'socket]
      [(6) 'character-device]
      [(7) 'block-device]
      [else 'unknown]))

  (define (vfs-path-separator? character)
    (or
      (char=? character #\/)
      (char=? character (directory-separator))))

  (define (vfs-directory-path path)
    (if
      (and
        (positive? (string-length path))
        (vfs-path-separator?
          (string-ref path (- (string-length path) 1))))
      path
      (string-append path (string (directory-separator)))))

  (define (expand-home-path path)
    (let ([home (getenv "HOME")])
      (cond
        [(or (not home) (zero? (string-length path))) path]
        [(string=? path "~") home]
        [(and
           (> (string-length path) 1)
           (char=? (string-ref path 0) #\~)
           (vfs-path-separator? (string-ref path 1)))
         (if (= (string-length path) 2)
             (vfs-directory-path home)
             (path-build home (substring path 2 (string-length path))))]
        [else path])))

  (define (path-components path)
    (let ([length (string-length path)])
      (let loop ([index 0] [start 0] [components '()])
        (cond
          [(= index length)
           (reverse
             (if (= start length)
                 components
                 (cons (substring path start length) components)))]
          [(vfs-path-separator? (string-ref path index))
           (loop
             (+ index 1)
             (+ index 1)
             (if (= start index)
                 components
                 (cons (substring path start index) components)))]
          [else (loop (+ index 1) start components)]))))

  (define (normalize-components components absolute?)
    (let loop ([remaining components] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(or (string=? (car remaining) "")
             (string=? (car remaining) "."))
         (loop (cdr remaining) result)]
        [(string=? (car remaining) "..")
         (cond
           [(and (pair? result) (not (string=? (car result) "..")))
            (loop (cdr remaining) (cdr result))]
           [absolute? (loop (cdr remaining) result)]
           [else (loop (cdr remaining) (cons ".." result))])]
        [else (loop (cdr remaining) (cons (car remaining) result))])))

  (define (join-components components)
    (if
      (null? components)
      ""
      (let loop ([remaining (cdr components)] [result (car components)])
        (if
          (null? remaining)
          result
          (loop
            (cdr remaining)
            (string-append
              result
              (string (directory-separator))
              (car remaining)))))))

  (define (vfs-normalize-path path)
    (let* ([absolute? (path-absolute? path)]
           [body
             (join-components
               (normalize-components
                 (path-components path)
                 absolute?))])
      (cond
        [(and absolute? (zero? (string-length body)))
         (string (directory-separator))]
        [absolute?
         (string-append (string (directory-separator)) body)]
        [(zero? (string-length body)) "."]
        [else body])))

  (define (vfs-resolve-path base-directory path)
    (let ([expanded (expand-home-path path)])
      (vfs-normalize-path
        (if (path-absolute? expanded)
            expanded
            (path-build base-directory expanded)))))

  (define (vfs-parent-directory path)
    (vfs-directory-path
      (path-parent
        (vfs-resolve-path
          (vfs-directory-path (current-directory))
          path))))

  (define (vfs-path-field-boundaries input point)
    (let ([start
            (let loop ([index (- point 1)])
              (cond
                [(negative? index) 0]
                [(vfs-path-separator? (string-ref input index)) (+ index 1)]
                [else (loop (- index 1))]))]
          [end
            (let loop ([index point])
              (cond
                [(= index (string-length input)) index]
                [(vfs-path-separator? (string-ref input index)) (+ index 1)]
                [else (loop (+ index 1))]))])
      (cons start end)))

  (define (vfs-completion-directory base input point)
    (let* ([start (car (vfs-path-field-boundaries input point))]
           [prefix (substring input 0 start)])
      (if (zero? (string-length prefix))
          base
          (vfs-resolve-path base prefix))))

  (define (vfs-path-join directory name)
    (vfs-resolve-path directory name))

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
                    (vfs-entry-kind-code
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
                   entries))))]))))

  (define (bytevector-u64-little-endian bytes offset)
    (let loop ([index 7] [value 0])
      (if
        (negative? index)
        value
        (loop
          (- index 1)
          (+
            (bitwise-arithmetic-shift-left value 8)
            (bytevector-u8-ref bytes (+ offset index)))))))

  (define (unsigned-u64->signed value)
    (if
      (>= value (expt 2 63))
      (- value (expt 2 64))
      value))

  (define (decode-vfs-stat kind data)
    (unless (= (bytevector-length data) 40)
      (assertion-violation
        'decode-vfs-stat
        "stat payload must contain five 64-bit fields"
        (bytevector-length data)))
    (make-vfs-stat
      (vfs-entry-kind-code kind)
      (bytevector-u64-little-endian data 0)
      (unsigned-u64->signed
        (bytevector-u64-little-endian data 8))
      (unsigned-u64->signed
        (bytevector-u64-little-endian data 16))
      (bytevector-u64-little-endian data 24)
      (bytevector-u64-little-endian data 32)))

  (define (vfs-stat-same-version? left right)
    (unless (and (vfs-stat? left) (vfs-stat? right))
      (assertion-violation
        'vfs-stat-same-version?
        "expected two VFS stat values"
        left
        right))
    (and
      (eq? (vfs-stat-kind left) (vfs-stat-kind right))
      (= (vfs-stat-size left) (vfs-stat-size right))
      (= (vfs-stat-mtime-seconds left)
         (vfs-stat-mtime-seconds right))
      (= (vfs-stat-mtime-nanoseconds left)
         (vfs-stat-mtime-nanoseconds right))
      (= (vfs-stat-device left) (vfs-stat-device right))
      (= (vfs-stat-inode left) (vfs-stat-inode right)))))
