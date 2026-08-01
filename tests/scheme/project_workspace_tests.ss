#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor language-session)
        (soda editor project)
        (soda editor project-workspace)
        (soda editor resource-context)
        (soda editor state))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation
      'project-workspace-tests message irritants)))

(define document (make-document "" 18001))
(define buffer
  (make-buffer 18002 document "*project-workspace*" 'fundamental-mode))
(define editor (make-editor-state buffer))
(for-each
  (lambda (finder) (editor-register-project-finder! editor finder))
  (built-in-project-finders))

(define outer
  (make-project
    'outer
    '("/workspace")
    'manual 'explicit #f
    (make-project-settings-layer
      '((language-server . clangd)
        (clangd-arguments . ("--background-index"))))
    '()))
(define inner
  (make-project
    'inner
    '("/workspace/component" "/workspace/generated")
    'manual 'explicit #f
    (make-project-settings-layer
      '((language-server . clangd)
        (compile-commands . "/workspace/build")))
    '()))
(editor-remember-project! editor outer)
(editor-remember-project! editor inner)

(define nested-workspaces
  (editor-project-workspaces-for-resource
    editor
    "/workspace/component/src/main.cpp"
    #f
    (lambda (path) 'absent)))
(check
  (equal?
    (map project-workspace-project-id nested-workspaces)
    '(inner outer))
  "resource ownership must prefer the most specific Project root")

(define hinted-workspace
  (editor-project-workspace-for-resource
    editor
    "/workspace/component/src/main.cpp"
    outer
    (lambda (path) 'absent)))
(check
  (eq? (project-workspace-project-id hinted-workspace) 'outer)
  "an applicable frozen Project hint must take precedence")

(define inner-workspace
  (editor-project-workspace editor inner))
(check
  (and
    (equal?
      (project-workspace-folder-resources inner-workspace)
      '("/workspace/component" "/workspace/generated"))
    (equal?
      (map project-workspace-folder-name
           (project-workspace-folders inner-workspace))
      '("component" "generated"))
    (string=?
      (project-workspace-setting-ref
        inner-workspace 'compile-commands "")
      "/workspace/build"))
  "ProjectWorkspace must freeze folders and declarative settings")

(define mutable-configuration
  (list
    (cons 'lsp-settings
          (list (cons 'clangd (vector "--background-index"))))))
(define mutable-project
  (make-project
    'mutable
    '("/mutable-workspace")
    'manual 'explicit #f
    (make-project-settings-layer mutable-configuration)
    '()))
(editor-remember-project! editor mutable-project)
(define mutable-workspace
  (editor-project-workspace editor mutable-project))
(vector-set!
  (cdr (assq 'clangd (cdr (assq 'lsp-settings mutable-configuration))))
  0
  "--changed")
(let ([exposed (project-workspace-configuration mutable-workspace)])
  (vector-set!
    (cdr (assq 'clangd (cdr (assq 'lsp-settings exposed))))
    0
    "--also-changed"))
(check
  (string=?
    (vector-ref
      (cdr
        (assq
          'clangd
          (cdr
            (assq
              'lsp-settings
              (project-workspace-configuration mutable-workspace)))))
      0)
    "--background-index")
  "workspace configuration must remain stable across caller mutation")

(define inner-generation (project-workspace-generation inner-workspace))
(define updated-inner
  (make-project
    'inner
    '("/workspace/component" "/workspace/generated")
    'manual 'updated #f
    (make-project-settings-layer
      '((language-server . clangd)
        (compile-commands . "/workspace/out")))
    '()))
(editor-update-project! editor updated-inner)
(define updated-workspace
  (editor-project-workspace editor inner))
(check
  (and
    (= (project-workspace-generation updated-workspace)
       (+ inner-generation 1))
    (eq? (project-workspace-project updated-workspace) updated-inner)
    (string=?
      (project-workspace-setting-ref
        updated-workspace 'compile-commands "")
      "/workspace/out"))
  "a workspace snapshot must use the current canonical Project revision")

(define language-key
  (project-workspace-language-session-key
    updated-workspace
    'cpp
    'clangd
    '((compile-commands . "/workspace/out"))
    '("clang" "22")
    '(completion diagnostics semantic-tokens)))
(check
  (and
    (equal?
      (language-session-key-workspace-folders language-key)
      '("/workspace/component" "/workspace/generated"))
    (equal?
      (language-session-key-configuration language-key)
      '((compile-commands . "/workspace/out")))
    (equal?
      (language-session-key-environment-fingerprint language-key)
      '("clang" "22")))
  "ProjectWorkspace must build a complete LanguageSession identity")

(define mutable-folders (list "/workspace/component"))
(define mutable-session-configuration
  (list (cons 'server (vector "clangd"))))
(define immutable-session-key
  (make-language-session-key
    'cpp
    'clangd
    mutable-folders
    mutable-session-configuration
    '() '()))
(vector-set! (cdr (assq 'server mutable-session-configuration)) 0 "changed")
(let ([exposed (language-session-key-configuration immutable-session-key)])
  (vector-set! (cdr (assq 'server exposed)) 0 "also-changed"))
(check
  (and
    (equal?
      (language-session-key-workspace-folders immutable-session-key)
      '("/workspace/component"))
    (equal?
      (vector->list
        (cdr
          (assq
            'server
            (language-session-key-configuration immutable-session-key))))
      '("clangd")))
  "LanguageSession identity inputs must remain stable across caller mutation")

(define discovered-workspace
  (editor-project-workspace-for-resource
    editor
    "/new-project/src/main.c"
    #f
    (lambda (path)
      (if (string=? path "/new-project/.git") 'present 'absent))))
(check
  (and
    discovered-workspace
    (string=?
      (project-workspace-folder-resource
        (car (project-workspace-folders discovered-workspace)))
      "/new-project"))
  "workspace resolution must discover an unregistered resource Project")

(check
  (not
    (editor-project-workspace-for-resource
      editor
      "/standalone/file.txt"
      #f
      (lambda (path) 'absent)))
  "a standalone resource must remain explicitly outside Project scope")

(define source-buffer
  (editor-create-buffer!
    editor
    "/workspace/component/src/other.cpp"
    'fundamental-mode
    ""))
(buffer-set-file-path!
  source-buffer "/workspace/component/src/other.cpp")
(define buffer-workspace
  (editor-project-workspace-for-buffer
    editor
    source-buffer
    (make-resource-context
      "/workspace"
      #f
      outer
      #f)
    (lambda (path) 'absent)))
(check
  (eq? (project-workspace-project-id buffer-workspace) 'outer)
  "Buffer bootstrap must honor an applicable frozen Project hint")
(check
  (not
    (editor-project-workspace-for-buffer
      editor
      buffer
      (make-resource-context "/workspace")
      (lambda (path) 'absent)))
  "generated Buffers must not acquire a Project language workspace")

(editor-close! editor)
(display "project workspace tests passed\n")
