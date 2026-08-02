(library (soda editor language-state)
  (export editor-ensure-language-session!
          editor-attach-language-session!
          editor-buffer-language-attachments
          editor-remove-language-session!
          editor-view-language-attachment
          editor-set-view-language-attachment!
          editor-select-unique-home-language-attachment!
          editor-bootstrap-view-language-session!
          adapt-language-context-to-buffer
          editor-view-resource-context
          editor-set-view-resource-context!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor invalidation)
          (soda editor language)
          (soda editor language-session)
          (soda editor project)
          (soda editor resource-context)
          (soda editor view)
          (soda editor window)
          (soda editor workbench)
          (soda vfs))

  (define (editor-views* value)
    (entity-registry-values (editor-view-registry value)))

  (define (editor-view-ref* value id)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-view-ref
        "view id must be a non-negative exact integer"
        id))
    (or (entity-registry-ref (editor-view-registry value) id)
        (assertion-violation 'editor-view-ref "unknown view id" id)))

  (define (editor-workbench-for-view* value view-id)
    (find
      (lambda (workbench)
        (let ([layout (workbench-layout workbench)])
          (let walk ([node layout])
            (if (window-leaf? node)
                (= (window-leaf-view-id node) view-id)
                (exists walk (window-split-children node))))))
      (entity-registry-values (editor-workbench-registry value))))

  (define (unique-workbench-project value view resource)
    (let ([workbench
            (editor-workbench-for-view* value (view-id view))])
      (and
        workbench
        (let ([projects
                (filter
                  (lambda (project)
                    (or
                      (not resource)
                      (project-contains-resource? project resource)))
                  (filter
                    (lambda (project) project)
                    (map
                      (lambda (project-id)
                        (project-catalog-find-known
                          (editor-project-catalog value)
                          project-id))
                      (workbench-scope workbench))))])
          (and (= (length projects) 1) (car projects))))))

  (define (context-with-project context origin-view-id project)
    (make-resource-context
      (resource-context-base-resource context)
      origin-view-id
      project
      (resource-context-language-context context)))

  (define (editor-ensure-language-session! value key)
    (require-open-editor 'editor-ensure-language-session! value)
    (language-session-registry-ensure!
      (editor-language-session-registry value)
      key))

  (define (editor-attach-language-session!
            value
            buffer-id
            session
            provenance
            origin-view-id)
    (require-open-editor 'editor-attach-language-session! value)
    (let ([buffer
            (entity-registry-ref
              (editor-buffer-registry value)
              buffer-id)])
      (unless buffer
        (assertion-violation
          'editor-attach-language-session!
          "unknown buffer id"
          buffer-id))
      (unless (language-session? session)
        (assertion-violation
          'editor-attach-language-session!
          "expected a LanguageSession"
          session))
      (let ([registered
              (language-session-registry-session-ref
                (editor-language-session-registry value)
                (language-session-id session))])
        (unless (eq? registered session)
          (assertion-violation
            'editor-attach-language-session!
            "LanguageSession belongs to another editor"
            session)))
      (let ([attachment
              (language-session-registry-attach!
                (editor-language-session-registry value)
                buffer-id
                (language-session-id session)
                provenance
                origin-view-id
                (buffer-revision buffer))])
        (when (eq? provenance 'home)
          (let ([homes
                  (filter
                    (lambda (candidate)
                      (eq? (language-attachment-provenance candidate) 'home))
                    (language-session-registry-buffer-attachments
                      (editor-language-session-registry value)
                      buffer-id))])
            (when (= (length homes) 1)
              (for-each
                (lambda (view)
                  (when (and (eq? (view-buffer view) buffer)
                             (not
                               (editor-view-language-attachment
                                 value (view-id view))))
                    (editor-set-view-language-attachment!
                      value (view-id view) attachment)))
                (editor-views* value)))))
        attachment)))

  (define (editor-buffer-language-attachments value buffer-id)
    (require-open-editor 'editor-buffer-language-attachments value)
    (or
      (entity-registry-ref (editor-buffer-registry value) buffer-id)
      (assertion-violation
        'editor-buffer-language-attachments
        "unknown buffer id"
        buffer-id))
    (language-session-registry-buffer-attachments
      (editor-language-session-registry value)
      buffer-id))

  (define (editor-remove-language-session! value session-id)
    (require-open-editor 'editor-remove-language-session! value)
    (let* ([removed
             (language-session-registry-remove-session!
               (editor-language-session-registry value)
               session-id)]
           [removed-ids
             (map language-attachment-id removed)])
      (for-each
        (lambda (view)
          (let ([language-context
                  (resource-context-language-context
                    (view-resource-context view))])
            (when
              (and
                (view-language-context? language-context)
                (memv
                  (view-language-context-attachment-id language-context)
                  removed-ids))
              (editor-set-view-language-attachment!
                value (view-id view) #f))))
        (editor-views* value))
      removed))

  (define (editor-view-language-attachment value view-id)
    (require-open-editor 'editor-view-language-attachment value)
    (let* ([context
             (view-resource-context (editor-view-ref* value view-id))]
           [language-context
             (resource-context-language-context context)])
      (and
        (view-language-context? language-context)
        (language-session-registry-attachment-ref
          (editor-language-session-registry value)
          (view-language-context-attachment-id language-context)))))

  (define (editor-set-view-language-attachment!
            value view-id attachment)
    (require-open-editor 'editor-set-view-language-attachment! value)
    (let ([view (editor-view-ref* value view-id)])
      (when attachment
        (unless (language-attachment? attachment)
          (assertion-violation
            'editor-set-view-language-attachment!
            "expected a LanguageAttachment or #f"
            attachment))
        (let ([registered
                (language-session-registry-attachment-ref
                  (editor-language-session-registry value)
                  (language-attachment-id attachment))])
          (unless
            (and
              (eq? registered attachment)
              (= (language-attachment-buffer-id attachment)
                 (buffer-id (view-buffer view))))
            (assertion-violation
              'editor-set-view-language-attachment!
              "attachment does not belong to the View Buffer"
              attachment))))
      (view-resource-context-set!
        view
        (resource-context-with-language-context
          (view-resource-context view)
          (and
            attachment
            (make-view-language-context
              (language-attachment-id attachment)))))
      (editor-invalidate! value 'configuration)
      attachment))

  (define (buffer-home-language-attachments value buffer)
    (filter
      (lambda (attachment)
        (eq? (language-attachment-provenance attachment) 'home))
      (editor-buffer-language-attachments value (buffer-id buffer))))

  (define (editor-select-unique-home-language-attachment! value view)
    (let ([home
            (buffer-home-language-attachments value (view-buffer view))])
      (and
        (= (length home) 1)
        (editor-set-view-language-attachment!
          value (view-id view) (car home)))))

  (define (bootstrap-buffer-home-language-attachment!
            value buffer context origin-view-id)
    (let* ([profile (buffer-language-profile buffer)]
           [bootstrap (and profile (language-profile-bootstrap profile))]
           [key (and bootstrap (bootstrap value buffer context))])
      (and
        key
        (begin
          (unless (language-session-key? key)
            (assertion-violation
              'editor-bootstrap-view-language-session!
              "bootstrap policy must return a LanguageSession key or #f"
              key))
          (let ([session (editor-ensure-language-session! value key)])
            (editor-attach-language-session!
              value
              (buffer-id buffer)
              session
              'home
              origin-view-id))))))

  (define (editor-bootstrap-view-language-session! value view-id)
    (require-open-editor 'editor-bootstrap-view-language-session! value)
    (let* ([view (editor-view-ref* value view-id)]
           [selected (editor-view-language-attachment value view-id)])
      (or
        selected
        (let* ([buffer (view-buffer view)]
               [home (buffer-home-language-attachments value buffer)])
          (cond
            [(= (length home) 1)
             (editor-set-view-language-attachment!
               value view-id (car home))]
            [(pair? home) #f]
            [else
             (let ([attachment
                     (bootstrap-buffer-home-language-attachment!
                       value
                       buffer
                       (editor-view-resource-context value view-id)
                       view-id)])
               (if (not attachment)
                   #f
                   (editor-set-view-language-attachment!
                     value view-id attachment)))])))))

  (define (adapt-language-context-to-buffer value context buffer)
    (let ([language-context
            (resource-context-language-context context)])
      (if (not (view-language-context? language-context))
          context
          (let* ([registry (editor-language-session-registry value)]
                 [source
                   (language-session-registry-attachment-ref
                     registry
                     (view-language-context-attachment-id language-context))]
                 [homes (buffer-home-language-attachments value buffer)]
                 [home
                   (cond
                     [(= (length homes) 1) (car homes)]
                     [(pair? homes) #f]
                     [else
                      (bootstrap-buffer-home-language-attachment!
                        value
                        buffer
                        context
                        (resource-context-origin-view-id context))])]
                 [target
                   (cond
                     [home home]
                     [(pair? homes) #f]
                     [(= (language-attachment-buffer-id source)
                         (buffer-id buffer))
                      source]
                     [else
                      (language-session-registry-attach!
                        registry
                        (buffer-id buffer)
                        (language-attachment-session-id source)
                        'inherited
                        (resource-context-origin-view-id context)
                        (buffer-revision buffer))])])
            (resource-context-with-language-context
              context
              (and
                target
                (make-view-language-context
                  (language-attachment-id target))))))))

  (define (editor-view-resource-context value view-id)
    (require-open-editor 'editor-view-resource-context value)
    (let* ([view (editor-view-ref* value view-id)]
           [context (view-resource-context view)]
           [buffer (view-buffer view)]
           [path (buffer-file-path buffer)]
           [creation-context (buffer-creation-context buffer)])
      (cond
        [path
         (let* ([resource (resource-context-resolve context path)]
                [hint (resource-context-project-hint context)]
                [project
                  (or
                    (and
                      hint
                      (project-contains-resource? hint resource)
                      hint)
                    (unique-workbench-project value view resource))])
           (make-resource-context
             (vfs-parent-directory resource)
             view-id
             project
             (resource-context-language-context context)))]
        [creation-context
         (let ([project
                 (or
                   (resource-context-project-hint creation-context)
                   (unique-workbench-project
                     value
                     view
                     (resource-context-base-resource creation-context)))])
           (context-with-project
             creation-context view-id project))]
        [(resource-context-project-hint context)
         (resource-context-with-origin context view-id)]
        [else
         (let ([project (unique-workbench-project value view #f)])
           (if project
               (make-resource-context
                 (project-primary-root project)
                 view-id
                 project
                 (resource-context-language-context context))
               (resource-context-with-origin context view-id)))])))

  (define (editor-set-view-resource-context! value view-id context)
    (require-open-editor 'editor-set-view-resource-context! value)
    (unless (resource-context? context)
      (assertion-violation
        'editor-set-view-resource-context!
        "expected a resource context"
        context))
    (let ([view (editor-view-ref* value view-id)])
      (view-resource-context-set!
        view
        (resource-context-with-origin
          (adapt-language-context-to-buffer
            value context (view-buffer view))
          view-id))
      (editor-invalidate! value 'configuration)
      (view-resource-context view)))
)
