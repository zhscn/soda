(library (soda support vfs)
  (export vfs-entry?
          vfs-entry-name
          vfs-entry-kind
          vfs-read-file
          vfs-write-file
          vfs-create-exclusive-file!
          vfs-delete-file-if-matches!
          vfs-file-exists?
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
                get-mode
                getenv
                get-process-id
                open-file-input-port
                open-file-output-port
                path-absolute?
                path-build
                path-parent
                rename-file
                chmod
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

  (define (vfs-file-exists? path)
    (require-path 'vfs-file-exists? path)
    (file-regular? path #t))

  (define atomic-write-serial 0)

  (define (next-atomic-write-path path)
    (set! atomic-write-serial (+ atomic-write-serial 1))
    (string-append path ".soda-write-"
                   (number->string (get-process-id)) "-"
                   (number->string atomic-write-serial)))

  (define (vfs-path-present? path)
    (or (file-regular? path #f)
        (file-directory? path #f)
        (file-symbolic-link? path)))

  (define (open-atomic-write-port path)
    ;; The default R6RS output-file behavior refuses an existing temporary
    ;; name.  Existing temporary names are skipped without opening them for
    ;; truncation; all other I/O errors retain their original condition.
    (let loop ()
      (let ([temporary (next-atomic-write-path path)])
        (if (vfs-path-present? temporary)
            (loop)
            (cons temporary
                  (open-file-output-port
                    temporary (file-options) (buffer-mode block) #f))))))

  (define (delete-file-if-present path)
    (when path
      (guard (condition [else #f])
        (delete-file path))))

  (define (write-file-contents path data)
    (call-with-port
      (open-file-output-port
        path (file-options no-fail) (buffer-mode block) #f)
      (lambda (port)
        (put-bytevector port data)
        (flush-output-port port))))

  ;; Replacing a regular file uses a same-directory temporary followed by
  ;; rename.  On the supported Unix targets `rename-file` is an atomic name
  ;; replacement.  Symbolic links retain the established VFS behavior of
  ;; writing their referent instead of replacing the link itself.
  (define (atomic-write-file path data)
    (if (file-symbolic-link? path)
        (write-file-contents path data)
        (let ([temporary #f] [replaced? #f]
              [mode (and (vfs-file-exists? path) (get-mode path))])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ([opened (open-atomic-write-port path)])
                (set! temporary (car opened))
                (call-with-port
                  (cdr opened)
                  (lambda (port)
                    (put-bytevector port data)
                    (flush-output-port port)))
                (when mode (chmod temporary mode))
                (rename-file temporary path)
                (set! replaced? #t)))
            (lambda ()
              (unless replaced? (delete-file-if-present temporary)))))))

  (define (vfs-write-file path data)
    (require-path 'vfs-write-file path)
    (unless (bytevector? data)
      (assertion-violation
        'vfs-write-file "data must be a bytevector" data))
    (atomic-write-file path data)
    (bytevector-length data))

  ;; Claim a path without a check-then-create race.  The default R6RS output
  ;; port mode creates a missing file and fails when a name already exists;
  ;; Chez implements this operation atomically on the supported file systems.
  ;; A preexisting path is reported as #f while unrelated I/O failures retain
  ;; their original condition.
  (define (vfs-create-exclusive-file! path data)
    (require-path 'vfs-create-exclusive-file! path)
    (unless (bytevector? data)
      (assertion-violation 'vfs-create-exclusive-file!
                           "data must be a bytevector" data))
    (guard (condition
            [else
             (if (vfs-path-present? path)
                 #f
                 (raise condition))])
      (call-with-port
        (open-file-output-port path (file-options) (buffer-mode block) #f)
        (lambda (port)
          (put-bytevector port data)
          (flush-output-port port)))
      #t))

  ;; Lock owners release only a file whose token is still theirs.  This is a
  ;; cooperative lock-file protocol: replacing a lock externally leaves the
  ;; replacement in place rather than deleting a lock another owner created.
  (define (vfs-delete-file-if-matches! path expected)
    (require-path 'vfs-delete-file-if-matches! path)
    (unless (bytevector? expected)
      (assertion-violation 'vfs-delete-file-if-matches!
                           "expected contents must be a bytevector" expected))
    (guard (condition [else #f])
      (and (vfs-file-exists? path)
           (bytevector=? (vfs-read-file path) expected)
           (begin (delete-file path) #t))))

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
