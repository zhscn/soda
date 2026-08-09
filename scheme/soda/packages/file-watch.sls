(library (soda packages file-watch)
  (export make-file-watch-service
          file-watch-service?
          file-watch-service-attach-runtime!
          file-watch-service-register!
          file-watch-service-update!
          file-watch-service-unregister!
          file-watch-service-add-listener!
          file-watch-service-handle-runtime-event!
          file-watch-service-binding-count
          file-watch-service-directory-count
          file-state-event?
          file-state-event-buffer-id
          file-state-event-path
          file-state-event-kind
          file-state-event-origin
          file-state-event-version
          file-state-event-causes
          file-state-event-status)
  (import (rnrs)
          (prefix (soda ffi runtime) native:)
          (soda host value)
          (soda support vfs))

  ;; FileWatchService translates native directory notifications into events
  ;; about a bound resource.  A directory has one native watch regardless of
  ;; how many Buffers visit files below it; Buffer bindings retain their own
  ;; acknowledged and locally-written versions.
  (define-record-type
    (file-watch-service %make-file-watch-service file-watch-service?)
    (fields owner bindings directories sources
            (mutable listeners file-watch-service-listeners
                               file-watch-service-listeners-set!)
            (mutable runtime file-watch-service-runtime
                             file-watch-service-runtime-set!)))

  (define-record-type
    (file-watch-binding %make-file-watch-binding file-watch-binding?)
    (fields buffer-id path directory name
            (mutable version file-watch-binding-version
                             file-watch-binding-version-set!)
            (mutable local-version file-watch-binding-local-version
                                   file-watch-binding-local-version-set!)))

  (define-record-type
    (directory-watch %make-directory-watch directory-watch?)
    (fields path bindings
            (mutable source directory-watch-source directory-watch-source-set!)))

  (define-record-type
    (file-state-event %make-file-state-event file-state-event?)
    (fields buffer-id path kind origin version causes status))

  (define (valid-buffer-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (valid-version? value)
    (or (not value) (vfs-stat? value)))

  (define (path-name path)
    (let loop ([index (- (string-length path) 1)])
      (cond
        [(negative? index) path]
        [(vfs-path-separator? (string-ref path index))
         (substring path (+ index 1) (string-length path))]
        [else (loop (- index 1))])))

  (define (path-version path)
    (and (vfs-file-exists? path) (vfs-stat-path path)))

  (define (make-file-watch-service owner)
    (unless (owner? owner)
      (assertion-violation 'make-file-watch-service "expected an Owner" owner))
    (owner-assert-active 'make-file-watch-service owner)
    (let ([service
           (%make-file-watch-service
             owner (make-eqv-hashtable) (make-hashtable string-hash string=?)
             (make-eqv-hashtable) '() #f)])
      (owner-add-cleanup!
        owner
        (lambda ()
          (let ([runtime (file-watch-service-runtime service)])
            (when runtime
              (call-with-values
                (lambda () (hashtable-entries (file-watch-service-sources service)))
                (lambda (keys values)
                  (for-each
                    (lambda (source)
                      (guard (ignored [else #f])
                        (native:runtime-cancel! runtime source)))
                    (vector->list keys)))))
            (hashtable-clear! (file-watch-service-bindings service))
            (hashtable-clear! (file-watch-service-directories service))
            (hashtable-clear! (file-watch-service-sources service))
            (file-watch-service-listeners-set! service '())
            (file-watch-service-runtime-set! service #f))))
      service))

  (define (start-directory-watch! service watch)
    (let ([runtime (file-watch-service-runtime service)])
      (when (and runtime (not (directory-watch-source watch)))
        (let ([source (native:runtime-watch-path! runtime (directory-watch-path watch))])
          (directory-watch-source-set! watch source)
          (hashtable-set! (file-watch-service-sources service) source watch)))))

  (define (stop-directory-watch! service watch)
    (let ([source (directory-watch-source watch)]
          [runtime (file-watch-service-runtime service)])
      (when source
        (hashtable-delete! (file-watch-service-sources service) source)
        (directory-watch-source-set! watch #f)
        (when runtime
          (guard (ignored [else #f])
            (native:runtime-cancel! runtime source))))))

  (define (file-watch-service-attach-runtime! service runtime)
    (unless (and (file-watch-service? service) (native:runtime? runtime))
      (assertion-violation 'file-watch-service-attach-runtime!
                           "expected a FileWatchService and native Runtime"
                           service runtime))
    (owner-assert-active 'file-watch-service-attach-runtime!
                         (file-watch-service-owner service))
    (let ([current (file-watch-service-runtime service)])
      (unless (eq? current runtime)
        (when current
          (call-with-values
            (lambda () (hashtable-entries (file-watch-service-directories service)))
            (lambda (keys values)
              (for-each
                (lambda (watch) (stop-directory-watch! service watch))
                (vector->list values)))))
        (file-watch-service-runtime-set! service runtime)
        (call-with-values
          (lambda () (hashtable-entries (file-watch-service-directories service)))
          (lambda (keys values)
            (for-each
              (lambda (watch) (start-directory-watch! service watch))
              (vector->list values))))))
    service)

  (define (ensure-directory-watch! service directory)
    (let* ([table (file-watch-service-directories service)]
           [existing (hashtable-ref table directory #f)])
      (or existing
          (let ([watch (%make-directory-watch directory (make-eqv-hashtable) #f)])
            (hashtable-set! table directory watch)
            (guard
              (condition
                [else
                 (hashtable-delete! table directory)
                 (raise condition)])
              (start-directory-watch! service watch)
              watch)))))

  (define (file-watch-service-unregister! service buffer-id)
    (unless (and (file-watch-service? service) (valid-buffer-id? buffer-id))
      (assertion-violation 'file-watch-service-unregister!
                           "expected a FileWatchService and Buffer id"
                           service buffer-id))
    (let* ([bindings (file-watch-service-bindings service)]
           [binding (hashtable-ref bindings buffer-id #f)])
      (and binding
           (begin
             (hashtable-delete! bindings buffer-id)
             (let* ([directory (file-watch-binding-directory binding)]
                    [watch
                     (hashtable-ref
                       (file-watch-service-directories service) directory #f)])
               (when watch
                 (hashtable-delete! (directory-watch-bindings watch) buffer-id)
                 (when (zero? (hashtable-size (directory-watch-bindings watch)))
                   (stop-directory-watch! service watch)
                   (hashtable-delete!
                     (file-watch-service-directories service) directory))))
             #t))))

  (define (file-watch-service-register! service buffer-id path version)
    (unless (and (file-watch-service? service) (valid-buffer-id? buffer-id)
                 (string? path) (positive? (string-length path))
                 (valid-version? version))
      (assertion-violation 'file-watch-service-register!
                           "invalid file watch binding" service buffer-id path version))
    (owner-assert-active 'file-watch-service-register!
                         (file-watch-service-owner service))
    (file-watch-service-unregister! service buffer-id)
    (let* ([directory (vfs-parent-directory path)]
           [watch (ensure-directory-watch! service directory)]
           [binding
            (%make-file-watch-binding
              buffer-id path directory (path-name path) version #f)])
      (hashtable-set! (file-watch-service-bindings service) buffer-id binding)
      (hashtable-set! (directory-watch-bindings watch) buffer-id binding)
      binding))

  ;; A successful local write acknowledges the new disk version and tags it
  ;; so delayed native notifications can be distinguished from external work.
  (define (file-watch-service-update! service buffer-id path version local?)
    (unless (and (file-watch-service? service) (valid-buffer-id? buffer-id)
                 (string? path) (positive? (string-length path))
                 (valid-version? version) (boolean? local?))
      (assertion-violation 'file-watch-service-update!
                           "invalid file watch update"
                           service buffer-id path version local?))
    (let ([binding
           (hashtable-ref (file-watch-service-bindings service) buffer-id #f)])
      (if (and binding (string=? path (file-watch-binding-path binding)))
          (begin
            (file-watch-binding-version-set! binding version)
            (file-watch-binding-local-version-set! binding (and local? version))
            binding)
          (let ([next
                 (file-watch-service-register! service buffer-id path version)])
            (file-watch-binding-local-version-set! next (and local? version))
            next))))

  (define (file-watch-service-add-listener! service owner procedure)
    (unless (and (file-watch-service? service) (owner? owner)
                 (procedure? procedure))
      (assertion-violation 'file-watch-service-add-listener!
                           "expected a FileWatchService, Owner, and listener"
                           service owner procedure))
    (owner-assert-active 'file-watch-service-add-listener! owner)
    (let ([entry (cons owner procedure)])
      (file-watch-service-listeners-set!
        service (append (file-watch-service-listeners service) (list entry)))
      (make-registration
        owner
        (lambda ()
          (file-watch-service-listeners-set!
            service
            (filter (lambda (candidate) (not (eq? candidate entry)))
                    (file-watch-service-listeners service)))))))

  (define (event-causes flags)
    (append
      (if (not (zero? (bitwise-and flags native:path-rename))) '(rename) '())
      (if (not (zero? (bitwise-and flags native:path-change))) '(change) '())))

  (define (same-version? left right)
    (and left right (vfs-stat-same-version? left right)))

  (define (notify-binding! service binding status flags)
    (let* ([path (file-watch-binding-path binding)]
           [current (and (not (negative? status)) (path-version path))]
           [local (file-watch-binding-local-version binding)]
           [origin (if (same-version? local current) 'local 'external)]
           [kind
            (cond
              [(negative? status) 'error]
              [(not current) 'deleted]
              [(not (zero? (bitwise-and flags native:path-rename))) 'replaced]
              [(same-version? current (file-watch-binding-version binding)) 'metadata]
              [else 'modified])]
           [event
            (%make-file-state-event
              (file-watch-binding-buffer-id binding) path kind origin current
              (event-causes flags) status)])
      ;; One filesystem operation may emit several native notifications.  A
      ;; matching acknowledged version remains local for all of them; it is
      ;; retired when a different disk version is observed or the binding is
      ;; explicitly updated by a later load/write.
      (when (and local (not (same-version? local current)))
        (file-watch-binding-local-version-set! binding #f))
      (for-each (lambda (entry) ((cdr entry) event))
                (file-watch-service-listeners service))
      event))

  (define (event-name event)
    (guard (ignored [else #f])
      (let ([data (native:event-data event)])
        (and (positive? (bytevector-length data)) (utf8->string data)))))

  (define (file-watch-service-handle-runtime-event! service event)
    (unless (and (file-watch-service? service) (native:event? event))
      (assertion-violation 'file-watch-service-handle-runtime-event!
                           "expected a FileWatchService and native event"
                           service event))
    (and (eq? (native:event-kind event) 'path-change)
         (let ([watch
                (hashtable-ref
                  (file-watch-service-sources service)
                  (native:event-source event) #f)])
           (and watch
                (let ([name (event-name event)]
                      [events '()])
                  (call-with-values
                    (lambda () (hashtable-entries (directory-watch-bindings watch)))
                    (lambda (keys values)
                      (for-each
                        (lambda (binding)
                          (when (or (not name)
                                    (string=? name (file-watch-binding-name binding)))
                            (set! events
                              (cons
                                (notify-binding!
                                  service binding (native:event-status event)
                                  (native:event-flags event))
                                events))))
                        (vector->list values))))
                  (reverse events))))))

  (define (file-watch-service-binding-count service)
    (unless (file-watch-service? service)
      (assertion-violation 'file-watch-service-binding-count
                           "expected a FileWatchService" service))
    (hashtable-size (file-watch-service-bindings service)))

  (define (file-watch-service-directory-count service)
    (unless (file-watch-service? service)
      (assertion-violation 'file-watch-service-directory-count
                           "expected a FileWatchService" service))
    (hashtable-size (file-watch-service-directories service)))
)
