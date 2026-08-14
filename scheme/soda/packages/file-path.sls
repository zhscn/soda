(library (soda packages file-path)
  (export buffer-id?
          canonical-file-resource
          file-backup-path
          file-lock?
          acquire-file-lock
          release-file-lock!
          file-name-completion-source
          make-file-name-reader)
  (import (rnrs)
          (only (chezscheme) current-directory get-process-id)
          (soda kernel resource)
          (soda host command)
          (soda packages completion)
          (soda packages interaction)
          (soda support vfs))

  (define-record-type file-lock
    (fields path token))

  (define (buffer-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (require-path who path)
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation who "expected a non-empty file name" path)))

  (define (canonical-file-resource path)
    (require-path 'canonical-file-resource path)
    (make-resource 'file
      (vfs-resolve-path (vfs-directory-path (current-directory)) path)))

  (define (file-backup-path path) (string-append path "~"))

  (define (file-lock-file-path resource)
    (string-append (resource-locator resource) ".soda-lock"))

  (define file-lock-serial 0)

  (define (next-file-lock-token)
    (set! file-lock-serial (+ file-lock-serial 1))
    (string->utf8
      (string-append "soda " (number->string (get-process-id)) " "
                     (number->string file-lock-serial) "\n")))

  (define (acquire-file-lock resource)
    (let* ([path (file-lock-file-path resource)]
           [token (next-file-lock-token)])
      (and (vfs-create-exclusive-file! path token)
           (make-file-lock path token))))

  (define (release-file-lock! lock)
    (and lock
         (vfs-delete-file-if-matches!
           (file-lock-path lock) (file-lock-token lock))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and (<= length (string-length value))
           (string=? prefix (substring value 0 length)))))

  (define (path-field-start value point)
    (let loop ([index (- point 1)])
      (cond [(negative? index) 0]
            [(vfs-path-separator? (string-ref value index)) (+ index 1)]
            [else (loop (- index 1))])))

  (define (path-field-end value point)
    (let loop ([index point])
      (cond [(= index (string-length value)) index]
            [(vfs-path-separator? (string-ref value index)) index]
            [else (loop (+ index 1))])))

  ;; File-name completion has no project ownership.  It resolves the path
  ;; field under point against the process directory, preserving the spelling
  ;; already typed in the prompt for the candidate insertion text.
  (define (file-name-candidates snapshot)
    (let* ([input (prompt-snapshot-input snapshot)]
           [point (prompt-snapshot-point snapshot)]
           [length (string-length input)])
      (let* ([start (path-field-start input point)]
                 [end (path-field-end input point)]
                 [directory-prefix (substring input 0 start)]
                 [name-prefix (substring input start point)]
                 [directory
                  (if (zero? (string-length directory-prefix))
                      (vfs-directory-path (current-directory))
                      (vfs-resolve-path
                        (vfs-directory-path (current-directory)) directory-prefix))])
            (guard (condition [else '()])
              (map
                (lambda (entry)
                  (let* ([name (vfs-entry-name entry)]
                         [directory? (eq? (vfs-entry-kind entry) 'directory)]
                         [label (if directory? (vfs-directory-path name) name)]
                         [behavior (if directory? 'continue 'final)]
                         [replacement-end
                          (if (and directory? (< end length)
                                   (vfs-path-separator?
                                     (string-ref input end)))
                              (+ end 1)
                              end)])
                    (make-replacement-completion-candidate
                      (vfs-path-join directory name) start replacement-end label label
                      (if directory? "directory" "file") "file" entry behavior)))
                (filter
                  (lambda (entry)
                    (and (not (string=? (vfs-entry-name entry) "."))
                         (not (string=? (vfs-entry-name entry) ".."))
                         (string-prefix? name-prefix (vfs-entry-name entry))))
                  (vfs-list-directory directory)))))))

  (define file-name-completion-source
    (make-completion-source file-name-candidates #f #f #f))

  (define (make-file-name-reader prompt)
    (make-interactive-reader
      'file-name
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request
            'file-name prompt #f file-name-completion-source 'free
            #f 'file-name)
          (lambda (value) (make-interactive-ready (list value)))))))
)
