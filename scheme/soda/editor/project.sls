(library (soda editor project)
  (export make-project
          project?
          project-id
          project-roots
          project-primary-root
          project-kind
          project-discovery-provenance
          project-resource-enumerator
          project-settings-layer
          project-task-definitions
          project-contains-resource?
          make-project-finder
          make-marker-project-finder
          project-finder?
          project-finder-name
          project-finder-priority
          project-finder-procedure
          project-discovery-unavailable
          make-project-catalog
          project-catalog?
          project-catalog-generation
          project-catalog-finders
          project-catalog-register-finder!
          project-catalog-remove-finder!
          project-catalog-find-finder
          project-catalog-discover
          project-catalog-clear-discovery-cache!
          project-catalog-known-projects
          project-catalog-remember!
          project-catalog-forget!
          project-catalog-find-known
          project-catalog-snapshot
          project-catalog-restore!
          default-project-marker-probe
          built-in-project-finders)
  (import (rnrs)
          (soda vfs))

  (define-record-type
    (project %make-project project?)
    (fields id
            roots
            kind
            discovery-provenance
            resource-enumerator
            settings-layer
            task-definitions))

  (define-record-type
    (project-finder %make-project-finder project-finder?)
    (fields name priority procedure))

  (define-record-type
    (project-catalog %make-project-catalog project-catalog?)
    (fields
      (mutable finders project-catalog-finders project-catalog-finders-set!)
      (mutable generation
               project-catalog-generation
               project-catalog-generation-set!)
      positive-cache
      negative-cache
      projects
      (mutable known-ids
               project-catalog-known-ids
               project-catalog-known-ids-set!)))

  (define-record-type
    (project-catalog-state
      %make-project-catalog-state
      project-catalog-state?)
    (fields finders generation projects known-ids))

  (define project-discovery-unavailable
    (list 'project-discovery-unavailable))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (valid-id? value)
    (or (symbol? value) (non-empty-string? value)))

  (define (make-project
            id
            roots
            kind
            discovery-provenance
            resource-enumerator
            settings-layer
            task-definitions)
    (unless (valid-id? id)
      (assertion-violation
        'make-project
        "id must be a symbol or non-empty string"
        id))
    (unless
      (and
        (list? roots)
        (pair? roots)
        (for-all non-empty-string? roots))
      (assertion-violation
        'make-project
        "roots must be a non-empty list of non-empty strings"
        roots))
    (unless (symbol? kind)
      (assertion-violation
        'make-project
        "kind must be a symbol"
        kind))
    (unless
      (or (not resource-enumerator) (procedure? resource-enumerator))
      (assertion-violation
        'make-project
        "resource enumerator must be a procedure or #f"
        resource-enumerator))
    (unless (list? task-definitions)
      (assertion-violation
        'make-project
        "task definitions must be a list"
        task-definitions))
    (%make-project
      id
      (map vfs-normalize-path roots)
      kind
      discovery-provenance
      resource-enumerator
      settings-layer
      task-definitions))

  (define (project-primary-root value)
    (unless (project? value)
      (assertion-violation
        'project-primary-root
        "expected a project"
        value))
    (car (project-roots value)))

  (define (path-prefix? prefix path)
    (let ([prefix-length (string-length prefix)]
          [path-length (string-length path)])
      (and
        (<= prefix-length path-length)
        (string=? prefix (substring path 0 prefix-length))
        (or
          (= prefix-length path-length)
          (vfs-path-separator? (string-ref path prefix-length))
          (and
            (positive? prefix-length)
            (vfs-path-separator?
              (string-ref prefix (- prefix-length 1))))))))

  (define (project-contains-resource? value resource)
    (unless (project? value)
      (assertion-violation
        'project-contains-resource?
        "expected a project"
        value))
    (unless (non-empty-string? resource)
      (assertion-violation
        'project-contains-resource?
        "resource must be a non-empty string"
        resource))
    (let ([normalized (vfs-normalize-path resource)])
      (exists
        (lambda (root) (path-prefix? root normalized))
        (project-roots value))))

  (define (make-project-finder name priority procedure)
    (unless (symbol? name)
      (assertion-violation
        'make-project-finder
        "name must be a symbol"
        name))
    (unless (and (integer? priority) (exact? priority))
      (assertion-violation
        'make-project-finder
        "priority must be an exact integer"
        priority))
    (unless (procedure? procedure)
      (assertion-violation
        'make-project-finder
        "procedure must be a procedure"
        procedure))
    (%make-project-finder name priority procedure))

  (define (project-id-for-marker kind directory)
    (string-append
      (symbol->string kind)
      ":"
      (vfs-normalize-path directory)))

  (define (make-marker-project-finder name priority kind markers)
    (unless (symbol? kind)
      (assertion-violation
        'make-marker-project-finder
        "kind must be a symbol"
        kind))
    (unless
      (and
        (list? markers)
        (pair? markers)
        (for-all non-empty-string? markers))
      (assertion-violation
        'make-marker-project-finder
        "markers must be a non-empty list of non-empty strings"
        markers))
    (make-project-finder
      name
      priority
      (lambda (directory probe)
        (let loop ([remaining markers] [unavailable? #f])
          (if
            (null? remaining)
            (if unavailable?
                project-discovery-unavailable
                #f)
            (let* ([marker (car remaining)]
                   [result (probe (vfs-path-join directory marker))])
              (case result
                [(present)
                 (make-project
                   (project-id-for-marker kind directory)
                   (list directory)
                   kind
                   (list
                     (cons 'finder name)
                     (cons 'marker marker))
                   #f
                   '()
                   '())]
                [(absent) (loop (cdr remaining) unavailable?)]
                [(unavailable)
                 (loop (cdr remaining) #t)]
                [else
                 (assertion-violation
                   name
                   "project marker probe returned an invalid result"
                   result)])))))))

  (define (make-project-catalog)
    (%make-project-catalog
      '()
      0
      (make-hashtable string-hash string=?)
      (make-hashtable string-hash string=?)
      (make-hashtable equal-hash equal?)
      '()))

  (define (require-catalog who catalog)
    (unless (project-catalog? catalog)
      (assertion-violation who "expected a project catalog" catalog)))

  (define (insert-finder finder finders)
    (cond
      [(null? finders) (list finder)]
      [(> (project-finder-priority finder)
          (project-finder-priority (car finders)))
       (cons finder finders)]
      [else
       (cons (car finders) (insert-finder finder (cdr finders)))]))

  (define (project-catalog-clear-discovery-cache! catalog)
    (require-catalog 'project-catalog-clear-discovery-cache! catalog)
    (hashtable-clear! (project-catalog-positive-cache catalog))
    (hashtable-clear! (project-catalog-negative-cache catalog))
    catalog)

  (define (project-catalog-find-finder catalog name)
    (require-catalog 'project-catalog-find-finder catalog)
    (unless (symbol? name)
      (assertion-violation
        'project-catalog-find-finder
        "name must be a symbol"
        name))
    (find
      (lambda (finder) (eq? (project-finder-name finder) name))
      (project-catalog-finders catalog)))

  (define (project-catalog-register-finder! catalog finder)
    (require-catalog 'project-catalog-register-finder! catalog)
    (unless (project-finder? finder)
      (assertion-violation
        'project-catalog-register-finder!
        "expected a project finder"
        finder))
    (project-catalog-finders-set!
      catalog
      (insert-finder
        finder
        (filter
          (lambda (existing)
            (not
              (eq?
                (project-finder-name existing)
                (project-finder-name finder))))
          (project-catalog-finders catalog))))
    (project-catalog-generation-set!
      catalog
      (+ (project-catalog-generation catalog) 1))
    (project-catalog-clear-discovery-cache! catalog)
    finder)

  (define (project-catalog-remove-finder! catalog name)
    (require-catalog 'project-catalog-remove-finder! catalog)
    (let ([finder (project-catalog-find-finder catalog name)])
      (when finder
        (project-catalog-finders-set!
          catalog
          (remq finder (project-catalog-finders catalog)))
        (project-catalog-generation-set!
          catalog
          (+ (project-catalog-generation catalog) 1))
        (project-catalog-clear-discovery-cache! catalog))
      finder))

  (define (intern-project! catalog value)
    (let* ([id (project-id value)]
           [existing
             (hashtable-ref (project-catalog-projects catalog) id #f)])
      (if existing
          existing
          (begin
            (hashtable-set! (project-catalog-projects catalog) id value)
            value))))

  (define (directory-parent directory)
    (vfs-normalize-path (vfs-parent-directory directory)))

  (define (discover-at-directory catalog directory probe)
    (let loop ([finders (project-catalog-finders catalog)]
               [unavailable? #f])
      (if
        (null? finders)
        (values #f unavailable?)
        (let ([result
                ((project-finder-procedure (car finders))
                 directory
                 probe)])
          (cond
            [(project? result) (values result unavailable?)]
            [(eq? result project-discovery-unavailable)
             (loop (cdr finders) #t)]
            [(not result) (loop (cdr finders) unavailable?)]
            [else
             (assertion-violation
               (project-finder-name (car finders))
               "project finder returned an invalid result"
               result)])))))

  (define (project-catalog-discover catalog directory probe)
    (require-catalog 'project-catalog-discover catalog)
    (unless (non-empty-string? directory)
      (assertion-violation
        'project-catalog-discover
        "directory must be a non-empty string"
        directory))
    (unless (procedure? probe)
      (assertion-violation
        'project-catalog-discover
        "probe must be a procedure"
        probe))
    (let* ([start (vfs-normalize-path directory)]
           [positive
             (hashtable-ref
               (project-catalog-positive-cache catalog)
               start
               #f)])
      (cond
        [positive positive]
        [(hashtable-contains?
           (project-catalog-negative-cache catalog)
           start)
         #f]
        [else
         (let loop ([current start] [unavailable? #f])
           (let-values
             ([(found current-unavailable?)
               (discover-at-directory catalog current probe)])
             (cond
               [found
                (let ([canonical (intern-project! catalog found)])
                  (hashtable-set!
                    (project-catalog-positive-cache catalog)
                    start
                    canonical)
                  canonical)]
               [else
                (let* ([unavailable?
                         (or unavailable? current-unavailable?)]
                       [parent (directory-parent current)])
                  (if (string=? parent current)
                      (begin
                        (unless unavailable?
                          (hashtable-set!
                            (project-catalog-negative-cache catalog)
                            start
                            #t))
                        #f)
                      (loop parent unavailable?)))])))])))

  (define (project-catalog-find-known catalog id)
    (require-catalog 'project-catalog-find-known catalog)
    (unless (valid-id? id)
      (assertion-violation
        'project-catalog-find-known
        "id must be a symbol or non-empty string"
        id))
    (and
      (member id (project-catalog-known-ids catalog))
      (hashtable-ref (project-catalog-projects catalog) id #f)))

  (define (project-catalog-known-projects catalog)
    (require-catalog 'project-catalog-known-projects catalog)
    (filter
      project?
      (map
        (lambda (id)
          (hashtable-ref (project-catalog-projects catalog) id #f))
        (project-catalog-known-ids catalog))))

  (define (project-catalog-remember! catalog value)
    (require-catalog 'project-catalog-remember! catalog)
    (unless (project? value)
      (assertion-violation
        'project-catalog-remember!
        "expected a project"
        value))
    (let* ([canonical (intern-project! catalog value)]
           [id (project-id canonical)])
      (unless (member id (project-catalog-known-ids catalog))
        (project-catalog-known-ids-set!
          catalog
          (append (project-catalog-known-ids catalog) (list id)))
        (project-catalog-generation-set!
          catalog
          (+ (project-catalog-generation catalog) 1)))
      canonical))

  (define (project-catalog-forget! catalog id)
    (require-catalog 'project-catalog-forget! catalog)
    (let ([existing (project-catalog-find-known catalog id)])
      (when existing
        (project-catalog-known-ids-set!
          catalog
          (filter
            (lambda (candidate) (not (equal? candidate id)))
            (project-catalog-known-ids catalog)))
        (project-catalog-generation-set!
          catalog
          (+ (project-catalog-generation catalog) 1)))
      existing))

  (define (hashtable->alist table)
    (let-values ([(keys values) (hashtable-entries table)])
      (let loop ([index 0] [result '()])
        (if (= index (vector-length keys))
            result
            (loop
              (+ index 1)
              (cons
                (cons
                  (vector-ref keys index)
                  (vector-ref values index))
                result))))))

  (define (project-catalog-snapshot catalog)
    (require-catalog 'project-catalog-snapshot catalog)
    (%make-project-catalog-state
      (project-catalog-finders catalog)
      (project-catalog-generation catalog)
      (hashtable->alist (project-catalog-projects catalog))
      (project-catalog-known-ids catalog)))

  (define (project-catalog-restore! catalog state)
    (require-catalog 'project-catalog-restore! catalog)
    (unless (project-catalog-state? state)
      (assertion-violation
        'project-catalog-restore!
        "expected a project catalog snapshot"
        state))
    (project-catalog-finders-set!
      catalog
      (project-catalog-state-finders state))
    (project-catalog-generation-set!
      catalog
      (project-catalog-state-generation state))
    (hashtable-clear! (project-catalog-projects catalog))
    (for-each
      (lambda (entry)
        (hashtable-set!
          (project-catalog-projects catalog)
          (car entry)
          (cdr entry)))
      (project-catalog-state-projects state))
    (project-catalog-known-ids-set!
      catalog
      (project-catalog-state-known-ids state))
    (project-catalog-clear-discovery-cache! catalog)
    catalog)

  (define (default-project-marker-probe path)
    (guard (condition [else 'unavailable])
      (if (file-exists? path) 'present 'absent)))

  (define (built-in-project-finders)
    (list
      (make-marker-project-finder
        'soda-project-marker
        300
        'soda
        '(".soda-project"))
      (make-marker-project-finder
        'build-project-marker
        200
        'build
        '("CMakeLists.txt"
          "meson.build"
          "Cargo.toml"
          "go.mod"
          "package.json"
          "pyproject.toml"))
      (make-marker-project-finder
        'vcs-project-marker
        100
        'vcs
        '(".git" ".hg" ".svn")))))
