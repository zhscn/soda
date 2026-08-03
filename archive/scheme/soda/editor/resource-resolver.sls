(library (soda editor resource-resolver)
  (export install-resource-resolver!
          editor-resolve-resources!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor file)
          (soda editor state))

  (define-record-type resource-resolution
    (fields resources success failure))

  (define pending-resolutions (make-weak-eq-hashtable))

  (define (unique-missing-resources editor resources)
    (reverse
      (fold-left
        (lambda (missing resource)
          (if (or (editor-buffer-for-resource editor resource)
                  (member resource missing))
              missing
              (cons resource missing)))
        '()
        resources)))

  (define (resolved-buffers editor resources)
    (map
      (lambda (resource)
        (editor-buffer-for-resource editor resource))
      resources))

  (define (editor-resolve-resources! editor resources success failure)
    (unless
      (and (editor? editor)
           (list? resources)
           (for-all
             (lambda (resource)
               (and (string? resource)
                    (positive? (string-length resource))))
             resources)
           (procedure? success)
           (procedure? failure))
      (assertion-violation
        'editor-resolve-resources!
        "invalid resource resolution request"
        editor resources success failure))
    (let ([missing (unique-missing-resources editor resources)])
      (if (null? missing)
          (begin
            (success editor (resolved-buffers editor resources))
            '())
          (begin
            (hashtable-set!
              pending-resolutions
              editor
              (append
                (hashtable-ref pending-resolutions editor '())
                (list (make-resource-resolution resources success failure))))
            (map
              (lambda (resource)
                (make-command-effect
                  'file.read
                  (make-open-request #f resource 0)))
              missing)))))

  (define (resolution-contains? resolution resource)
    (member resource (resource-resolution-resources resolution)))

  (define (resolution-ready? editor resolution)
    (for-all
      (lambda (resource)
        (editor-buffer-for-resource editor resource))
      (resource-resolution-resources resolution)))

  (define (resume-resolutions-after-open
            context arguments effects)
    (let* ([editor (command-context-editor context)]
           [result
             (let ([argument (command-context-argument context)])
               (and (open-result? argument) argument))]
           [pending
             (hashtable-ref pending-resolutions editor '())])
      (when (and result (pair? pending))
        (let ([resource (open-result-path result)]
              [remaining '()])
          (for-each
            (lambda (resolution)
              (if (not (resolution-contains? resolution resource))
                  (set! remaining (cons resolution remaining))
                  (cond
                    [(or (not (zero? (open-result-status result)))
                         (eq? (open-result-kind result) 'directory))
                     ((resource-resolution-failure resolution)
                      editor resource (open-result-status result))]
                    [(resolution-ready? editor resolution)
                     ((resource-resolution-success resolution)
                      editor
                      (resolved-buffers
                        editor
                        (resource-resolution-resources resolution)))]
                    [else
                     (set! remaining (cons resolution remaining))])))
            pending)
          (if (null? remaining)
              (hashtable-delete! pending-resolutions editor)
              (hashtable-set!
                pending-resolutions editor (reverse remaining)))))))

  (define (install-resource-resolver! editor)
    (command-add-advice!
      (editor-command-registry editor)
      'file.apply-open-result
      'resource-resolver
      'after
      resume-resolutions-after-open
      0)
    editor)
)
