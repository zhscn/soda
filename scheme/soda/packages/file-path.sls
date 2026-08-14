(library (soda packages file-path)
  (export buffer-id?
          canonical-file-resource
          file-backup-path
          file-lock?
          acquire-file-lock
          release-file-lock!
          current-file-directory
          make-file-name-completion-source
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

  (define (current-file-directory)
    (vfs-directory-path
      (vfs-resolve-path (vfs-directory-path (current-directory)) ".")))

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

  ;; A file prompt captures one directory base. Candidate discovery and final
  ;; submission both resolve against it, so changing process cwd while the
  ;; prompt is open cannot change the meaning of its text.
  (define (file-name-candidates base snapshot)
    (let* ([input (prompt-snapshot-input snapshot)]
           [point (prompt-snapshot-point snapshot)]
           [length (string-length input)]
           [boundaries (vfs-path-field-boundaries input point)])
      (let* ([start (car boundaries)]
                 [end (cdr boundaries)]
                 [name-prefix (substring input start point)]
                 [directory (vfs-completion-directory base input point)])
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

  (define (make-file-name-completion-source base)
    (unless (and (string? base) (positive? (string-length base)))
      (assertion-violation
        'make-file-name-completion-source "expected a base directory" base))
    (let ([directory (vfs-directory-path (vfs-resolve-path base "."))])
      (make-completion-source
        (lambda (snapshot) (file-name-candidates directory snapshot))
        #f #f #f)))

  (define file-name-completion-source
    (make-completion-source
      (lambda (snapshot)
        (file-name-candidates (current-file-directory) snapshot))
      #f #f #f))

  (define make-file-name-reader
    (case-lambda
      [(prompt)
       (make-file-name-reader prompt (lambda (context) (current-file-directory)))]
      [(prompt directory-for-context)
       (unless (and (string? prompt) (procedure? directory-for-context))
         (assertion-violation
           'make-file-name-reader "expected a prompt and directory resolver"))
       (make-interactive-reader
         'file-name
         (lambda (context arguments)
           (let* ([base
                   (vfs-directory-path
                     (vfs-resolve-path (directory-for-context context) "."))]
                  [source (make-file-name-completion-source base)])
             (make-interactive-suspend
               (make-interaction-request
                 'file-name prompt base source 'free #f 'file-name)
               (lambda (value)
                 (make-interactive-ready
                   (list (vfs-resolve-path base value))))))))]))
)
