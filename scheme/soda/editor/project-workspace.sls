(library (soda editor project-workspace)
  (export make-project-workspace-folder
          project-workspace-folder?
          project-workspace-folder-name
          project-workspace-folder-resource
          project-workspace?
          project-workspace-project
          project-workspace-project-id
          project-workspace-generation
          project-workspace-folders
          project-workspace-folder-resources
          project-workspace-configuration
          project-workspace-setting-ref
          editor-project-workspace
          editor-project-workspaces-for-resource
          editor-project-workspace-for-resource
          editor-project-workspace-for-buffer
          project-workspace-language-session-key)
  (import (rnrs)
          (soda editor buffer)
          (soda editor language-session)
          (soda editor project)
          (soda editor resource-context)
          (soda editor state)
          (soda vfs))

  (define-record-type
    (project-workspace-folder
      %make-project-workspace-folder
      project-workspace-folder?)
    (fields name resource))

  (define-record-type project-workspace
    (fields project project-id generation folders configuration))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (make-project-workspace-folder name resource)
    (unless (non-empty-string? name)
      (assertion-violation
        'make-project-workspace-folder
        "name must be a non-empty string"
        name))
    (unless (non-empty-string? resource)
      (assertion-violation
        'make-project-workspace-folder
        "resource must be a non-empty string"
        resource))
    (%make-project-workspace-folder
      name (vfs-normalize-path resource)))

  (define (path-name path)
    (let* ([normalized (vfs-normalize-path path)]
           [length (string-length normalized)])
      (let loop ([position (- length 1)])
        (cond
          [(negative? position) normalized]
          [(vfs-path-separator? (string-ref normalized position))
           (if (= position (- length 1))
               (loop (- position 1))
               (substring normalized (+ position 1) length))]
          [else (loop (- position 1))]))))

  (define (folders-for-roots roots)
    (let ([names (make-hashtable string-hash string=?)])
      (map
        (lambda (root)
          (let* ([base
                   (let ([name (path-name root)])
                     (if (zero? (string-length name)) root name))]
                 [count (+ 1 (hashtable-ref names base 0))]
                 [name
                   (if (= count 1)
                       base
                       (string-append
                         base " (" (number->string count) ")"))])
            (hashtable-set! names base count)
            (make-project-workspace-folder name root)))
        roots)))

  (define (project-configuration project)
    (let ([layer (project-settings-layer project)])
      (if layer
          (map
            (lambda (entry) (cons (car entry) (cdr entry)))
            (project-settings-layer-entries layer))
          '())))

  (define (editor-project-workspace editor project)
    (require-open-editor 'editor-project-workspace editor)
    (unless (project? project)
      (assertion-violation
        'editor-project-workspace "expected a Project" project))
    (let* ([catalog (editor-project-catalog editor)]
           [canonical
             (or
               (project-catalog-project-ref catalog (project-id project))
               project)]
           [generation
             (or
               (project-catalog-project-generation
                 catalog (project-id canonical))
               0)])
      (make-project-workspace
        canonical
        (project-id canonical)
        generation
        (folders-for-roots (project-roots canonical))
        (project-configuration canonical))))

  (define (project-workspace-folder-resources workspace)
    (unless (project-workspace? workspace)
      (assertion-violation
        'project-workspace-folder-resources
        "expected a ProjectWorkspace"
        workspace))
    (map
      project-workspace-folder-resource
      (project-workspace-folders workspace)))

  (define (project-workspace-setting-ref workspace name fallback)
    (unless (project-workspace? workspace)
      (assertion-violation
        'project-workspace-setting-ref
        "expected a ProjectWorkspace"
        workspace))
    (unless (symbol? name)
      (assertion-violation
        'project-workspace-setting-ref
        "setting name must be a symbol"
        name))
    (let ([entry (assq name (project-workspace-configuration workspace))])
      (if entry (cdr entry) fallback)))

  (define (root-contains-resource? root resource)
    (let ([root-length (string-length root)]
          [resource-length (string-length resource)])
      (and
        (<= root-length resource-length)
        (string=? root (substring resource 0 root-length))
        (or
          (= root-length resource-length)
          (vfs-path-separator? (string-ref resource root-length))
          (and
            (positive? root-length)
            (vfs-path-separator?
              (string-ref root (- root-length 1))))))))

  (define (project-score project resource)
    (fold-left
      (lambda (score root)
        (if
          (root-contains-resource? root resource)
          (max score (string-length root))
          score))
      -1
      (project-roots project)))

  (define (insert-project project projects resource)
    (cond
      [(null? projects) (list project)]
      [(> (project-score project resource)
          (project-score (car projects) resource))
       (cons project projects)]
      [else
       (cons
         (car projects)
         (insert-project project (cdr projects) resource))]))

  (define (sort-projects projects resource)
    (fold-left
      (lambda (result project)
        (insert-project project result resource))
      '()
      projects))

  (define (deduplicate-projects projects)
    (let loop ([remaining projects] [ids '()] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(member (project-id (car remaining)) ids)
         (loop (cdr remaining) ids result)]
        [else
         (loop
           (cdr remaining)
           (cons (project-id (car remaining)) ids)
           (cons (car remaining) result))])))

  (define editor-project-workspaces-for-resource
    (case-lambda
      [(editor resource)
       (editor-project-workspaces-for-resource editor resource #f #f)]
      [(editor resource hint)
       (editor-project-workspaces-for-resource editor resource hint #f)]
      [(editor resource hint probe)
       (require-open-editor
         'editor-project-workspaces-for-resource editor)
       (unless (non-empty-string? resource)
         (assertion-violation
           'editor-project-workspaces-for-resource
           "resource must be a non-empty string"
           resource))
       (unless (or (not hint) (project? hint))
         (assertion-violation
           'editor-project-workspaces-for-resource
           "hint must be a Project or #f"
           hint))
       (unless (or (not probe) (procedure? probe))
         (assertion-violation
           'editor-project-workspaces-for-resource
           "probe must be a procedure or #f"
           probe))
       (let* ([normalized (vfs-normalize-path resource)]
              [hint
                (and
                  hint
                  (project-contains-resource? hint normalized)
                  hint)]
              [discovered
                (if probe
                    (editor-discover-project editor normalized probe)
                    (editor-discover-project editor normalized))]
              [known
                (filter
                  (lambda (project)
                    (project-contains-resource? project normalized))
                  (editor-known-projects editor))]
              [ordered
                (append
                  (if hint (list hint) '())
                  (sort-projects
                    (append
                      (if discovered (list discovered) '())
                      known)
                    normalized))])
         (map
           (lambda (project)
             (editor-project-workspace editor project))
           (deduplicate-projects ordered)))]))

  (define editor-project-workspace-for-resource
    (case-lambda
      [(editor resource)
       (editor-project-workspace-for-resource editor resource #f #f)]
      [(editor resource hint)
       (editor-project-workspace-for-resource editor resource hint #f)]
      [(editor resource hint probe)
       (let ([workspaces
               (editor-project-workspaces-for-resource
                 editor resource hint probe)])
         (and (pair? workspaces) (car workspaces)))]))

  (define editor-project-workspace-for-buffer
    (case-lambda
      [(editor buffer context)
       (editor-project-workspace-for-buffer
         editor buffer context #f)]
      [(editor buffer context probe)
       (require-open-editor
         'editor-project-workspace-for-buffer editor)
       (unless (buffer? buffer)
         (assertion-violation
           'editor-project-workspace-for-buffer
           "expected a Buffer"
           buffer))
       (unless (or (not context) (resource-context? context))
         (assertion-violation
           'editor-project-workspace-for-buffer
           "context must be a ResourceContext or #f"
           context))
       (unless (or (not probe) (procedure? probe))
         (assertion-violation
           'editor-project-workspace-for-buffer
           "probe must be a procedure or #f"
           probe))
       (let ([resource (buffer-file-path buffer)])
         (and
           resource
           (editor-project-workspace-for-resource
             editor
             resource
             (and context (resource-context-project-hint context))
             probe)))]))

  (define project-workspace-language-session-key
    (case-lambda
      [(workspace language provider)
       (project-workspace-language-session-key
         workspace language provider
         (project-workspace-configuration workspace)
         #f
         '())]
      [(workspace language provider
         configuration environment-fingerprint client-capabilities)
       (unless (project-workspace? workspace)
         (assertion-violation
           'project-workspace-language-session-key
           "expected a ProjectWorkspace"
           workspace))
       (make-language-session-key
         language
         provider
         (project-workspace-folder-resources workspace)
         configuration
         environment-fingerprint
         client-capabilities)]))
)
