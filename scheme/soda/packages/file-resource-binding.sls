(library (soda packages file-resource-binding)
  (export file-service-binding
          file-service-resource
          file-service-format
          file-service-binding-at-path
          file-service-rename-resource!
          file-service-delete-resource!
          file-service-attach-runtime!
          set-file-resource!
          file-buffer-key
          clear-file-conflict!)
  (import (rnrs)
          (soda kernel resource)
          (soda host buffer)
          (soda host package)
          (soda packages file-format)
          (soda packages file-path)
          (soda packages file-service-value)
          (soda packages file-state)
          (soda packages file-watch)
          (soda support vfs))

  (define (file-service-binding service buffer-id . default)
    (unless (and (file-service? service) (buffer-id? buffer-id))
      (assertion-violation 'file-service-binding "expected a file service and Buffer id"
                           service buffer-id))
    (file-state-binding
      (file-service-state service) buffer-id
      (if (null? default) #f (car default))))

  (define (file-service-resource service buffer-id . default)
    (let ([binding (file-service-binding service buffer-id #f)])
      (if binding
          (file-binding-resource binding)
          (if (null? default) #f (car default)))))

  (define (file-service-format service buffer-id . default)
    (let ([binding (file-service-binding service buffer-id #f)])
      (if binding
          (file-binding-format binding)
          (if (null? default) #f (car default)))))

  (define (file-service-binding-at-path service path)
    (file-state-binding-at-path (file-service-state service) path))

  ;; Directory packages delegate file mutations here so Buffer identity,
  ;; locks, watches, and resource keys change as one host-owned operation.
  (define (file-service-rename-resource! service source destination expected)
    (unless (file-service? service)
      (assertion-violation 'file-service-rename-resource!
                           "expected a FileService" service))
    (let ([target (canonical-file-resource destination)])
      (let-values ([(buffer-id binding)
                    (file-service-binding-at-path service source)])
        (if (not binding)
            (vfs-rename-path-if-matches! source destination expected)
            (let* ([host (file-service-host service)]
                   [buffer (package-host-buffer-ref host buffer-id #f)]
                   [existing
                    (package-host-find-buffer-key
                      host (file-buffer-key target) #f)])
              (unless buffer
                (assertion-violation 'file-service-rename-resource!
                                     "visited file Buffer is no longer live" source))
              (when (and existing (not (= (buffer-id existing) buffer-id)))
                (assertion-violation 'file-service-rename-resource!
                                     "destination is already visited" destination))
              (let ([new-lock (acquire-file-lock target)]
                    [renamed? #f]
                    [committed? #f])
                (unless new-lock
                  (assertion-violation 'file-service-rename-resource!
                                       "destination is locked" destination))
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (vfs-rename-path-if-matches! source destination expected)
                    (set! renamed? #t)
                    (package-host-rebind-buffer-key!
                      host (file-buffer-key target) buffer)
                    (set-file-resource!
                      service buffer-id target (vfs-stat-path destination)
                      new-lock (file-binding-format binding) #t)
                    (release-file-lock! (file-binding-lock binding))
                    (clear-file-conflict! service buffer-id)
                    (set! committed? #t)
                    destination)
                  (lambda ()
                    (unless committed?
                      (when renamed? (vfs-rename-path! destination source))
                      (release-file-lock! new-lock))))))))))

  (define (file-service-delete-resource! service path expected)
    (unless (file-service? service)
      (assertion-violation 'file-service-delete-resource!
                           "expected a FileService" service))
    (let-values ([(buffer-id binding)
                  (file-service-binding-at-path service path)])
      (vfs-delete-path-if-matches! path expected)
      (when binding
        (release-file-lock! (file-binding-lock binding))
        (set-file-resource!
          service buffer-id (file-binding-resource binding) #f #f
          (file-binding-format binding) #t)
        (file-state-set-conflict!
          (file-service-state service) buffer-id
          (make-file-conflict
            buffer-id (file-binding-resource binding) #f 'deleted 'pending)))
      #t))

  (define set-file-resource!
    (case-lambda
      [(service buffer-id resource version)
       (set-file-resource! service buffer-id resource version #f
                      (make-default-file-format) #f)]
      [(service buffer-id resource version lock)
       (set-file-resource! service buffer-id resource version lock
                      (make-default-file-format) #f)]
      [(service buffer-id resource version lock format)
       (set-file-resource! service buffer-id resource version lock format #f)]
      [(service buffer-id resource version lock format local?)
       (unless (file-format? format)
         (assertion-violation 'set-file-resource!
                              "expected file format metadata" format))
       (let ([binding (make-file-binding resource version lock format)])
         (file-state-set-binding! (file-service-state service) buffer-id binding)
         (file-watch-service-update!
           (file-service-watch-service service) buffer-id
           (resource-locator resource) version local?)
         binding)]))

  (define (file-service-attach-runtime! service runtime)
    (unless (file-service? service)
      (assertion-violation 'file-service-attach-runtime!
                           "expected a FileService" service))
    (file-watch-service-attach-runtime!
      (file-service-watch-service service) runtime)
    service)

  (define (file-buffer-key resource)
    (make-buffer-key 'file (resource-locator resource)))

  (define (clear-file-conflict! service buffer-id)
    (file-state-clear-conflict! (file-service-state service) buffer-id))
)
