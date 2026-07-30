(library (soda editor scheme-interface-commands)
  (export install-scheme-interface-commands!
          make-scheme-interface-load-request
          scheme-interface-load-request?
          scheme-interface-load-request-path
          make-scheme-interface-load-result
          scheme-interface-load-result?
          scheme-interface-load-result-path
          scheme-interface-load-result-status
          scheme-interface-load-result-data
          scheme-interface-load-result-detail)
  (import (rnrs)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor file)
          (soda editor scheme-interface-index)
          (soda editor scheme-workspace)
          (soda editor state))

  (define-record-type
    (scheme-interface-load-request
      %make-scheme-interface-load-request
      scheme-interface-load-request?)
    (fields path))

  (define-record-type
    (scheme-interface-load-result
      %make-scheme-interface-load-result
      scheme-interface-load-result?)
    (fields path status data detail))

  (define (non-empty-string? value)
    (and
      (string? value)
      (positive? (string-length value))))

  (define (make-scheme-interface-load-request path)
    (unless (non-empty-string? path)
      (assertion-violation
        'make-scheme-interface-load-request
        "path must be a non-empty string"
        path))
    (%make-scheme-interface-load-request path))

  (define (make-scheme-interface-load-result
            path
            status
            data
            detail)
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
      path status data detail))

  (define-command
    (load-interface-index-command context path)
    "Load a compiled Scheme interface index into the language workspace."
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
            path)))))

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
            path)))))

  (define (apply-interface-index-command
            workspace
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
             (scheme-workspace-install-interface-index!
               workspace
               index)
             (scheme-workspace-sync-editor!
               workspace
               editor)
             (editor-set-status-message!
               editor
               (string-append
                 "Loaded Scheme interfaces "
                 (scheme-interface-index-owner index)
                 "@"
                 (scheme-interface-index-revision
                   index)))))]))
    '())

  (define (install-scheme-interface-commands!
            editor
            workspace)
    (unless (scheme-workspace-index? workspace)
      (assertion-violation
        'install-scheme-interface-commands!
        "expected a Scheme workspace index"
        workspace))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'scheme.load-interface-index
        load-interface-index-command
        "Load a compiled Scheme interface index into the language workspace."))
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
            workspace
            context))
        "Apply a Scheme interface index read result."))
    editor))
