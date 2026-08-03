(library (soda editor project-state)
  (export editor-register-project-finder!
          editor-remove-project-finder!
          editor-discover-project
          editor-known-projects
          editor-remember-project!
          editor-update-project!
          editor-forget-project!
          editor-project-resource-snapshot
          editor-apply-project-resource-snapshot!
          editor-clear-project-resource-snapshot!)
  (import (rnrs)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor hook)
          (soda editor invalidation)
          (soda editor project)
          (soda editor project-resource)
          (soda editor workbench))

  (define (editor-run-project-hooks! editor . arguments)
    (apply
      hook-registry-run!
      (editor-hook-registry editor)
      'project-registry-changed
      arguments))

  (define (editor-register-project-finder! value finder)
    (require-open-editor 'editor-register-project-finder! value)
    (unless (project-finder? finder)
      (assertion-violation
        'editor-register-project-finder!
        "expected a project finder"
        finder))
    (let ([registered
            (project-catalog-register-finder!
              (editor-project-catalog value)
              finder)])
      (editor-invalidate! value 'configuration)
      (editor-run-project-hooks!
        value
        value
        'discovery-policy-changed
        #f
        (project-catalog-generation (editor-project-catalog value)))
      registered))

  (define (editor-remove-project-finder! value name)
    (require-open-editor 'editor-remove-project-finder! value)
    (let ([removed
            (project-catalog-remove-finder!
              (editor-project-catalog value)
              name)])
      (when removed
        (editor-invalidate! value 'configuration)
        (editor-run-project-hooks!
          value
          value
          'discovery-policy-changed
          #f
          (project-catalog-generation
            (editor-project-catalog value))))
      removed))

  (define editor-discover-project
    (case-lambda
      [(value directory)
       (editor-discover-project
         value directory default-project-marker-probe)]
      [(value directory probe)
       (require-open-editor 'editor-discover-project value)
       (let* ([catalog (editor-project-catalog value)]
              [before (project-catalog-generation catalog)]
              [project
                (project-catalog-discover catalog directory probe)])
         (when (> (project-catalog-generation catalog) before)
           (editor-run-project-hooks!
             value
             value
             'discovered
             project
             (project-catalog-generation catalog)))
         project)]))

  (define (editor-known-projects value)
    (require-open-editor 'editor-known-projects value)
    (project-catalog-known-projects
      (editor-project-catalog value)))

  (define (editor-remember-project! value project)
    (require-open-editor 'editor-remember-project! value)
    (let* ([catalog (editor-project-catalog value)]
           [before
             (project-catalog-find-known catalog (project-id project))]
           [remembered
            (project-catalog-remember!
              catalog
              project)])
      (editor-invalidate! value 'configuration)
      (unless (eq? before remembered)
        (editor-run-project-hooks!
          value
          value
          (if before 'updated 'remembered)
          remembered
          (project-catalog-generation catalog)))
      remembered))

  (define (editor-update-project! value project)
    (require-open-editor 'editor-update-project! value)
    (unless (project? project)
      (assertion-violation
        'editor-update-project!
        "expected a Project"
        project))
    (let* ([catalog (editor-project-catalog value)]
           [before
             (project-catalog-find-known catalog (project-id project))]
           [updated (project-catalog-update! catalog project)])
      (editor-invalidate! value 'configuration)
      (unless (eq? before updated)
        (editor-run-project-hooks!
          value
          value
          (if before 'updated 'remembered)
          updated
          (project-catalog-generation catalog)))
      updated))

  (define (editor-forget-project! value id)
    (require-open-editor 'editor-forget-project! value)
    (let ([forgotten
            (project-catalog-forget!
              (editor-project-catalog value)
              id)])
      (when forgotten
        (for-each
          (lambda (workbench)
            (workbench-remove-project! workbench id))
          (entity-registry-values
            (editor-workbench-registry value)))
        (editor-invalidate! value 'configuration)
        (editor-run-project-hooks!
          value
          value
          'forgotten
          forgotten
          (project-catalog-generation
            (editor-project-catalog value))))
      forgotten))

  (define (editor-project-resource-snapshot value project-id)
    (require-open-editor 'editor-project-resource-snapshot value)
    (hashtable-ref
      (editor-project-resource-snapshots value)
      project-id
      #f))

  (define (editor-apply-project-resource-snapshot! value snapshot)
    (require-open-editor
      'editor-apply-project-resource-snapshot!
      value)
    (unless (project-resource-snapshot? snapshot)
      (assertion-violation
        'editor-apply-project-resource-snapshot!
        "expected a project resource snapshot"
        snapshot))
    (let* ([project-id
             (project-resource-snapshot-project-id snapshot)]
           [current
             (editor-project-resource-snapshot value project-id)])
      (if
        (and
          current
          (< (project-resource-snapshot-generation snapshot)
             (project-resource-snapshot-generation current)))
        #f
        (begin
          (hashtable-set!
            (editor-project-resource-snapshots value)
            project-id
            snapshot)
          (editor-invalidate! value 'project)
          snapshot))))

  (define (editor-clear-project-resource-snapshot! value project-id)
    (require-open-editor
      'editor-clear-project-resource-snapshot!
      value)
    (let ([snapshot
            (editor-project-resource-snapshot value project-id)])
      (when snapshot
        (hashtable-delete!
          (editor-project-resource-snapshots value)
          project-id)
        (editor-invalidate! value 'project))
      snapshot)))
