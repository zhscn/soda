(library (soda editor configuration)
  (export default-editor-init-path
          editor-init-loaded?
          load-editor-init!
          load-default-editor-init!
          reload-editor-init!)
  (import (rnrs)
          (only (chezscheme) getenv)
          (soda editor evaluator)
          (soda editor state))

  (define user-init-owner 'user-init)

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (default-editor-init-path)
    (let ([override (getenv "SODA_INIT_FILE")])
      (if override
          (and (non-empty-string? override) override)
          (let ([xdg-config-home (getenv "XDG_CONFIG_HOME")]
                [home (getenv "HOME")])
            (cond
              [(non-empty-string? xdg-config-home)
               (string-append xdg-config-home "/soda/init.ss")]
              [(non-empty-string? home)
               (string-append home "/.config/soda/init.ss")]
              [else #f])))))

  (define (editor-init-loaded? editor)
    (editor-extension-loaded? editor user-init-owner))

  (define (make-init-loader path)
    (lambda (editor)
      (let ([evaluator (make-chez-evaluator)])
        (chez-evaluator-evaluate-file! evaluator path editor)
        (editor-set-evaluator! editor evaluator))))

  (define (load-editor-init! editor path)
    (unless (non-empty-string? path)
      (assertion-violation
        'load-editor-init!
        "path must be a non-empty string"
        path))
    (unless (file-exists? path)
      (assertion-violation
        'load-editor-init!
        "init file does not exist"
        path))
    (editor-load-extension!
      editor
      user-init-owner
      (make-init-loader path))
    path)

  (define (load-default-editor-init! editor)
    (let ([path (default-editor-init-path)])
      (and path
           (file-exists? path)
           (load-editor-init! editor path))))

  (define (reload-editor-init! editor)
    (if (editor-init-loaded? editor)
        (begin
          (editor-reload-extension! editor user-init-owner)
          #t)
        (and (load-default-editor-init! editor) #t))))
