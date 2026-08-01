(library (soda editor project-target)
  (export make-project-target
          project-target?
          project-target-project
          project-target-root
          project-target-origin-workbench-id
          project-target-origin-view-id
          project-target-resource-context
          editor-view-home-project
          editor-resolve-project
          editor-project-target)
  (import (rnrs)
          (soda editor buffer)
          (soda editor project)
          (soda editor resource-context)
          (soda editor state)
          (soda editor workbench))

  (define-record-type project-target
    (fields
      project
      root
      origin-workbench-id
      origin-view-id
      resource-context))

  (define (known-scope-projects editor workbench)
    (filter
      (lambda (project) project)
      (map
        (lambda (id)
          (project-catalog-find-known
            (editor-project-catalog editor)
            id))
        (workbench-scope workbench))))

  (define (unique-scope-project editor workbench)
    (let ([projects (known-scope-projects editor workbench)])
      (and (= (length projects) 1) (car projects))))

  (define (editor-view-home-project editor view)
    (let* ([buffer (view-buffer view)]
           ;; buffer-resource is also the identity of generated buffers such
           ;; as *scratch*.  Visited files establish path ownership directly;
           ;; generated buffers discover from their local resource base after
           ;; consulting any Project captured at creation.
           [resource (buffer-file-path buffer)]
           [context
             (editor-view-resource-context editor (view-id view))]
           [hint (resource-context-project-hint context)])
      (if resource
          (or
            (and
              hint
              (project-contains-resource? hint resource)
              hint)
            (editor-discover-project editor resource))
          (or
            hint
            (editor-discover-project
              editor
              (resource-context-base-resource context))))))

  (define editor-resolve-project
    (case-lambda
      [(editor view policy)
       (editor-resolve-project editor view policy #f)]
      [(editor view policy explicit-project)
       (unless (memq policy '(workspace resource))
         (assertion-violation
           'editor-resolve-project
           "policy must be workspace or resource"
           policy))
       (unless (or (not explicit-project) (project? explicit-project))
         (assertion-violation
           'editor-resolve-project
           "explicit target must be a Project or #f"
           explicit-project))
       (let* ([workbench
                (editor-workbench-for-view editor (view-id view))]
              [focused
                (and
                  workbench
                  (editor-workbench-focused-project editor workbench))]
              [home (editor-view-home-project editor view)]
              [unique
                (and
                  workbench
                  (unique-scope-project editor workbench))])
         (or
           explicit-project
           (case policy
             [(workspace) (or focused home unique)]
             [(resource) (or home focused unique)])))]))

  (define editor-project-target
    (case-lambda
      [(editor view policy)
       (editor-project-target editor view policy #f)]
      [(editor view policy explicit-project)
       (let ([project
               (editor-resolve-project
                 editor view policy explicit-project)])
         (and
           project
           (let* ([workbench
                    (editor-workbench-for-view editor (view-id view))]
                  [current
                    (editor-view-resource-context editor (view-id view))]
                  [context
                    (make-resource-context
                      (project-primary-root project)
                      (view-id view)
                      project
                      (resource-context-language-context current))])
             (make-project-target
               project
               (project-primary-root project)
               (and workbench (workbench-id workbench))
               (view-id view)
               context))))]))
)
