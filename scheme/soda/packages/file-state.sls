(library (soda packages file-state)
  (export make-file-state
          file-state?
          file-state-binding
          file-state-binding-at-path
          file-state-set-binding!
          file-state-delete-buffer!
          file-binding?
          make-file-binding
          file-binding-resource
          file-binding-version
          file-binding-lock
          file-binding-format
          file-state-conflict
          file-state-set-conflict!
          file-state-clear-conflict!
          file-conflict?
          make-file-conflict
          file-conflict-buffer-id
          file-conflict-resource
          file-conflict-version
          file-conflict-kind
          file-conflict-status
          file-conflict-status-set!)
  (import (rnrs)
          (soda kernel resource))

  (define-record-type
    (file-state %make-file-state file-state?)
    (fields (immutable bindings file-state-bindings)
            (immutable conflicts file-state-conflicts)))

  (define-record-type file-binding
    (fields resource version lock format))

  (define-record-type
    (file-conflict make-file-conflict file-conflict?)
    (fields buffer-id resource version kind
            (mutable status file-conflict-status file-conflict-status-set!)))

  (define (make-file-state)
    (%make-file-state (make-eqv-hashtable) (make-eqv-hashtable)))

  (define (file-state-binding state buffer-id . default)
    (hashtable-ref
      (file-state-bindings state) buffer-id
      (if (null? default) #f (car default))))

  (define (file-state-binding-at-path state path)
    (let-values ([(ids bindings) (hashtable-entries (file-state-bindings state))])
      (let loop ([index 0])
        (if (= index (vector-length ids))
            (values #f #f)
            (let ([binding (vector-ref bindings index)])
              (if (string=? path
                            (resource-locator (file-binding-resource binding)))
                  (values (vector-ref ids index) binding)
                  (loop (+ index 1))))))))

  (define (file-state-set-binding! state buffer-id binding)
    (unless (file-binding? binding)
      (assertion-violation 'file-state-set-binding!
                           "expected a FileBinding" binding))
    (hashtable-set! (file-state-bindings state) buffer-id binding)
    binding)

  (define (file-state-delete-buffer! state buffer-id)
    (hashtable-delete! (file-state-bindings state) buffer-id)
    (hashtable-delete! (file-state-conflicts state) buffer-id))

  (define (file-state-conflict state buffer-id . default)
    (hashtable-ref
      (file-state-conflicts state) buffer-id
      (if (null? default) #f (car default))))

  (define (file-state-set-conflict! state buffer-id conflict)
    (unless (file-conflict? conflict)
      (assertion-violation 'file-state-set-conflict!
                           "expected a FileConflict" conflict))
    (hashtable-set! (file-state-conflicts state) buffer-id conflict)
    conflict)

  (define (file-state-clear-conflict! state buffer-id)
    (hashtable-delete! (file-state-conflicts state) buffer-id))
)
