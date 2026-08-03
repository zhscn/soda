(library (soda editor scheme-interface-commands)
  (export install-scheme-interface-commands!
          make-scheme-interface-load-request
          scheme-interface-load-request?
          scheme-interface-load-request-path
          scheme-interface-load-request-origin-view-id
          scheme-interface-load-request-origin-buffer-id
          scheme-interface-load-request-environment-id
          make-scheme-interface-load-result)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor contract)
          (soda editor file)
          (soda editor scheme-environment)
          (soda editor scheme-interface-index)
          (soda editor scheme-workspace)
          (soda editor state)
          (soda editor language-state))

  (define-record-type
    (scheme-interface-load-request
      %make-scheme-interface-load-request
      scheme-interface-load-request?)
    (fields path origin-view-id origin-buffer-id environment-id))

  (define-record-type
    (scheme-interface-load-result
      %make-scheme-interface-load-result
      scheme-interface-load-result?)
    (fields path origin-view-id origin-buffer-id environment-id status data detail))

  (define make-scheme-interface-load-request
    (case-lambda
      [(path)
       (make-scheme-interface-load-request path #f #f #f)]
      [(path origin-view-id environment-id)
       (make-scheme-interface-load-request
         path origin-view-id #f environment-id)]
      [(path origin-view-id origin-buffer-id environment-id)
       (unless
         (and
           (non-empty-string? path)
           (or (not origin-view-id)
               (and (integer? origin-view-id)
                    (exact? origin-view-id)
                    (not (negative? origin-view-id))))
           (or (not environment-id)
               (and (integer? environment-id)
                    (exact? environment-id)
                    (positive? environment-id)))
           (or (not origin-buffer-id)
               (and (integer? origin-buffer-id)
                    (exact? origin-buffer-id)
                    (positive? origin-buffer-id))))
         (assertion-violation
           'make-scheme-interface-load-request
           "invalid Scheme interface load request"
           path origin-view-id origin-buffer-id environment-id))
       (%make-scheme-interface-load-request
         path origin-view-id origin-buffer-id environment-id)]))

  (define make-scheme-interface-load-result
    (case-lambda
      [(path status data detail)
       (make-scheme-interface-load-result
         path #f #f #f status data detail)]
      [(path origin-view-id environment-id status data detail)
       (make-scheme-interface-load-result
         path origin-view-id #f environment-id status data detail)]
      [(path origin-view-id origin-buffer-id environment-id status data detail)
    (unless
      (and
        (non-empty-string? path)
        (integer? status)
        (exact? status)
        (bytevector? data)
        (or (not detail) (string? detail)))
      (assertion-violation
        'make-scheme-interface-load-result
        "invalid Scheme interface load result"
        path status data detail))
       (%make-scheme-interface-load-result
         path origin-view-id origin-buffer-id environment-id status data detail)]))

  (define-command
    (load-interface-index-command context path)
    "Load a compiled Scheme interface index into a SchemeEnvironment."
    (interactive
      (interactive-file-name
        "Load Scheme interface index: "))
    (let ([editor (command-context-editor context)])
      (editor-set-status-message!
        editor
        (string-append
          "Loading Scheme interface index "
          path))
      (list
        (make-command-effect
          'scheme.interface-index-read
          (make-scheme-interface-load-request
            path
            (view-id (command-context-view context))
            (buffer-id
              (view-buffer (command-context-view context)))
            #f)))))

  (define (load-interface-index-path-command context)
    (let ([path (command-context-argument context)])
      (unless (non-empty-string? path)
        (assertion-violation
          'scheme.load-interface-index-path
          "expected a non-empty path"
          path))
      (editor-set-status-message!
        (command-context-editor context)
        (string-append
          "Loading Scheme interface index "
          path))
      (list
        (make-command-effect
          'scheme.interface-index-read
          (make-scheme-interface-load-request
            path
            (view-id (command-context-view context))
            (buffer-id
              (view-buffer (command-context-view context)))
            #f)))))

  (define (apply-interface-index-command
            environments
            context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)])
      (unless (scheme-interface-load-result? result)
        (assertion-violation
          'scheme.apply-interface-index
          "expected a Scheme interface load result"
          result))
      (cond
        [(not
           (zero?
             (scheme-interface-load-result-status result)))
         (editor-set-status-message!
           editor
           (string-append
             "Cannot load Scheme interface index "
             (scheme-interface-load-result-path result)
             (let ([detail
                     (scheme-interface-load-result-detail
                       result)])
               (if detail
                   (string-append ": " detail)
                   ""))))]
        [else
         (guard
           (condition
             [else
              (editor-set-status-message!
                editor
                (string-append
                  "Invalid Scheme interface index "
                  (scheme-interface-load-result-path result)))])
           (let ([index
                   (scheme-interface-index-decode
                     (scheme-interface-load-result-data
                       result))])
             (let* ([environment
                      (if
                        (scheme-interface-load-result-environment-id result)
                        (scheme-environment-registry-ref
                          environments
                          (scheme-interface-load-result-environment-id result))
                        (scheme-environment-registry-ensure!
                          environments
                          (scheme-interface-index-owner index)
                          'r6rs))]
                    [origin-view-id
                      (or
                        (scheme-interface-load-result-origin-view-id result)
                        (view-id (command-context-view context)))])
               (unless
                 (scheme-interface-load-result-environment-id result)
                 (let* ([origin-buffer-id
                          (or
                            (scheme-interface-load-result-origin-buffer-id result)
                            (buffer-id
                              (view-buffer
                                (command-context-view context))))]
                        [attachment
                          (scheme-environment-attach-buffer!
                            environments
                            editor
                            origin-buffer-id
                            environment
                            origin-view-id)]
                        [origin-view
                          (editor-find-view editor origin-view-id)])
                   (when
                     (and
                       origin-view
                       (= origin-buffer-id
                          (buffer-id (view-buffer origin-view))))
                     (editor-set-view-language-attachment!
                       editor origin-view-id attachment))))
             (scheme-workspace-install-interface-index!
               (scheme-environment-index environment)
               index)
             (scheme-workspace-sync-editor!
               (scheme-environment-index environment)
               editor)
             (editor-set-status-message!
               editor
               (string-append
                 "Loaded Scheme interfaces "
                 (scheme-interface-index-owner index)
                 "@"
                 (scheme-interface-index-revision
                   index))))))]))
    '())

  (define (install-scheme-interface-commands!
            editor
            environments)
    (unless (scheme-environment-registry? environments)
      (assertion-violation
        'install-scheme-interface-commands!
        "expected a SchemeEnvironment registry"
        environments))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'scheme.load-interface-index
        load-interface-index-command
        "Load a compiled Scheme interface index into a SchemeEnvironment."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.load-interface-index-path
        load-interface-index-path-command
        "Load a compiled Scheme interface index from a supplied path."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.apply-interface-index
        (lambda (context)
          (apply-interface-index-command
            environments
            context))
        "Apply a Scheme interface index read result."))
    editor))
