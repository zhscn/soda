(library (soda support vfs)
  (export vfs-entry?
          vfs-entry-name
          vfs-entry-kind
          vfs-read-file
          vfs-write-file
          vfs-list-directory
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
          vfs-stat-same-version?
          vfs-stat-path)
  (import (rnrs)
          (only (chezscheme)
                current-directory
                directory-list
                directory-separator
                file-directory?
                file-length
                file-modification-time
                file-regular?
                file-symbolic-link?
                getenv
                open-file-input-port
                open-file-output-port
                path-absolute?
                path-build
                path-parent
                time-nanosecond
                time-second))

  (define-record-type vfs-entry
    (fields name kind))

  (define-record-type vfs-stat
    (fields kind size mtime-seconds mtime-nanoseconds))

  (define (require-path who path)
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation who "path must be a non-empty string" path)))

  (define (vfs-read-file path)
    (require-path 'vfs-read-file path)
    (call-with-port
      (open-file-input-port path (file-options) (buffer-mode block) #f)
      get-bytevector-all))

  (define (vfs-write-file path data)
    (require-path 'vfs-write-file path)
    (unless (bytevector? data)
      (assertion-violation
        'vfs-write-file "data must be a bytevector" data))
    (call-with-port
      (open-file-output-port
        path (file-options no-fail) (buffer-mode block) #f)
      (lambda (port)
        (put-bytevector port data)
        (flush-output-port port)))
    (bytevector-length data))

  (define (vfs-path-kind path follow?)
    (cond
      [(and (not follow?) (file-symbolic-link? path)) 'link]
      [(file-directory? path follow?) 'directory]
      [(file-regular? path follow?) 'file]
      [(file-symbolic-link? path) 'link]
      [else 'unknown]))

  (define (vfs-list-directory path)
    (require-path 'vfs-list-directory path)
    (map
      (lambda (name)
        (make-vfs-entry
          name
          (vfs-path-kind (path-build path name) #f)))
      (list-sort string<? (directory-list path))))

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

  (define vfs-stat-path
    (case-lambda
      [(path) (vfs-stat-path path #t)]
      [(path follow?)
       (require-path 'vfs-stat-path path)
       (let* ([kind (vfs-path-kind path follow?)]
              [modified (file-modification-time path follow?)]
              [size
                (if (eq? kind 'file)
                    (call-with-port
                      (open-file-input-port
                        path (file-options) (buffer-mode block) #f)
                      file-length)
                    0)])
         (make-vfs-stat
           kind size (time-second modified) (time-nanosecond modified)))]))

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
         (vfs-stat-mtime-nanoseconds right)))))
