(library (soda packages recovery)
  (export make-recovery-service!
          recovery-service?
          recovery-service-directory
          recovery-service-snapshot!
          recovery-service-clear-buffer!
          recovery-service-pending-artifacts
          recovery-artifact?
          recovery-artifact-path
          recovery-artifact-resource
          recovery-artifact-contents)
  (import (rnrs)
          (only (chezscheme) chmod current-directory getenv get-process-id)
          (soda kernel change)
          (soda kernel document)
          (soda kernel resource)
          (soda kernel state)
          (soda host buffer)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch-transaction)
          (soda host dispatch-core)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda packages base history)
          (soda packages completion)
          (soda packages interaction)
          (soda support vfs))

  ;; Recovery artifacts are independent snapshots of modified file Buffers.
  ;; They are not file backups and never replace or bind the original resource.
  ;; Restoration opens an ordinary unvisited Buffer containing the recovered
  ;; bytes, leaving the original file untouched until the user explicitly
  ;; saves the new Buffer.
  (define-record-type
    (recovery-artifact %make-recovery-artifact recovery-artifact?)
    (fields path resource
            (immutable contents recovery-artifact-contents-raw)))

  (define (recovery-artifact-contents artifact)
    (unless (recovery-artifact? artifact)
      (assertion-violation 'recovery-artifact-contents
                           "expected a RecoveryArtifact" artifact))
    (bytevector-copy (recovery-artifact-contents-raw artifact)))

  (define-record-type recovery-snapshot
    (fields buffer-id generation resource contents))

  (define-record-type
    (recovery-service %make-recovery-service recovery-service?)
    (fields host owner history resource-for-buffer directory pending queued live-artifacts
            (mutable pending-artifacts recovery-service-pending-artifacts-raw
                                       recovery-service-pending-artifacts-set!)))

  (define artifact-magic "SODA-RECOVERY-1 ")
  (define recovery-serial 0)

  (define (recovery-service-pending-artifacts service)
    (unless (recovery-service? service)
      (assertion-violation 'recovery-service-pending-artifacts
                           "expected a RecoveryService" service))
    (list-copy (recovery-service-pending-artifacts-raw service)))

  (define (default-recovery-directory)
    (let ([configured (getenv "SODA_RECOVERY_DIRECTORY")]
          [state-home (getenv "XDG_STATE_HOME")]
          [home (getenv "HOME")])
      (cond
        [(and configured (positive? (string-length configured))) configured]
        [(and state-home (positive? (string-length state-home)))
         (vfs-path-join (vfs-path-join state-home "soda") "recovery")]
        [(and home (positive? (string-length home)))
         (vfs-path-join
           (vfs-path-join (vfs-path-join home ".local") "state/soda")
           "recovery")]
        [else
         (vfs-path-join "/tmp" "soda-recovery")])))

  (define (bytevector-append . values)
    (let* ([size (fold-left (lambda (total value)
                              (+ total (bytevector-length value)))
                            0 values)]
           [result (make-bytevector size)])
      (let loop ([remaining values] [offset 0])
        (if (null? remaining)
            result
            (let* ([value (car remaining)]
                   [length (bytevector-length value)])
              (bytevector-copy! value 0 result offset length)
              (loop (cdr remaining) (+ offset length)))))))

  (define (encode-artifact resource contents)
    (let* ([path (string->utf8 (resource-locator resource))]
           [header
            (string->utf8
              (string-append artifact-magic
                             (number->string (bytevector-length path)) "\n"))])
      (bytevector-append header path contents)))

  (define (newline-offset bytes)
    (let loop ([index 0])
      (cond [(= index (bytevector-length bytes)) #f]
            [(= (bytevector-u8-ref bytes index) 10) index]
            [else (loop (+ index 1))])))

  (define (bytevector-slice bytes from to)
    (let ([result (make-bytevector (- to from))])
      (bytevector-copy! bytes from result 0 (- to from))
      result))

  (define (decode-artifact path)
    (guard (ignored [else #f])
      (let* ([bytes (vfs-read-file path)]
             [newline (newline-offset bytes)]
             [header (and newline
                          (utf8->string (bytevector-slice bytes 0 newline)))])
        (and header
             (>= (string-length header) (string-length artifact-magic))
             (string=? artifact-magic
                       (substring header 0 (string-length artifact-magic)))
             (let* ([length
                     (string->number
                       (substring header (string-length artifact-magic)
                                  (string-length header)))]
                    [start (+ newline 1)]
                    [end (and (integer? length) (exact? length)
                              (>= length 0) (+ start length))])
               (and end (<= end (bytevector-length bytes))
                    (let ([resource-path
                           (utf8->string (bytevector-slice bytes start end))])
                      (%make-recovery-artifact
                        path (make-resource 'file resource-path)
                        (bytevector-slice bytes end (bytevector-length bytes))))))))))

  (define (artifact-file? name)
    (let ([suffix ".soda-recovery"])
      (and (>= (string-length name) (string-length suffix))
           (string=? suffix
                     (substring name (- (string-length name) (string-length suffix))
                                (string-length name))))))

  (define (discover-artifacts directory)
    (if (not (vfs-directory-exists? directory))
        '()
        (fold-right
          (lambda (entry artifacts)
            (let ([artifact
                   (and (eq? (vfs-entry-kind entry) 'file)
                        (artifact-file? (vfs-entry-name entry))
                        (decode-artifact
                          (vfs-path-join directory (vfs-entry-name entry))))])
              (if artifact (cons artifact artifacts) artifacts)))
          '() (vfs-list-directory directory))))

  (define (next-artifact-path service buffer-id)
    (set! recovery-serial (+ recovery-serial 1))
    (vfs-path-join
      (recovery-service-directory service)
      (string-append
        "recovery-" (number->string (get-process-id)) "-"
        (number->string buffer-id) "-" (number->string recovery-serial)
        ".soda-recovery")))

  (define (live-artifact-path service buffer-id)
    (or (hashtable-ref (recovery-service-live-artifacts service) buffer-id #f)
        (let ([path (next-artifact-path service buffer-id)])
          (hashtable-set! (recovery-service-live-artifacts service) buffer-id path)
          path)))

  (define (queue-flush! service buffer-id)
    (unless (hashtable-ref (recovery-service-queued service) buffer-id #f)
      (hashtable-set! (recovery-service-queued service) buffer-id #t)
      (command-runtime-enqueue!
        (package-host-command-runtime (recovery-service-host service))
        (make-command-invoke-message
          'recovery.flush (make-command-context #f buffer-id 'recovery)
          (list buffer-id) #f))))

  (define (recovery-service-snapshot! service buffer-id generation resource contents)
    (unless (and (recovery-service? service)
                 (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                 (integer? generation) (exact? generation) (>= generation 0)
                 (resource? resource) (eq? (resource-scheme resource) 'file)
                 (bytevector? contents))
      (assertion-violation 'recovery-service-snapshot!
                           "invalid recovery snapshot"
                           service buffer-id generation resource))
    (hashtable-set!
      (recovery-service-pending service) buffer-id
      (make-recovery-snapshot
        buffer-id generation resource (bytevector-copy contents)))
    (queue-flush! service buffer-id)
    #t)

  (define (queue-clear! service buffer-id)
    (hashtable-set! (recovery-service-pending service) buffer-id 'clear)
    (queue-flush! service buffer-id))

  (define (delete-artifact! path)
    (when (and path (vfs-file-exists? path)) (delete-file path)))

  (define (clear-buffer-now! service buffer-id)
    (hashtable-delete! (recovery-service-pending service) buffer-id)
    (hashtable-delete! (recovery-service-queued service) buffer-id)
    (let ([path
           (hashtable-ref (recovery-service-live-artifacts service) buffer-id #f)])
      (hashtable-delete! (recovery-service-live-artifacts service) buffer-id)
      (delete-artifact! path))
    #t)

  (define (recovery-service-clear-buffer! service buffer-id)
    (unless (and (recovery-service? service)
                 (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0))
      (assertion-violation 'recovery-service-clear-buffer!
                           "expected a RecoveryService and Buffer id"
                           service buffer-id))
    ;; Callers may be Dispatcher or lifecycle listeners.  Keep filesystem I/O
    ;; at the command-loop effect boundary even when the Buffer has closed.
    (queue-clear! service buffer-id)
    #t)

  (define (flush-pending! service buffer-id)
    (let ([pending
           (hashtable-ref (recovery-service-pending service) buffer-id #f)])
      (hashtable-delete! (recovery-service-pending service) buffer-id)
      (hashtable-delete! (recovery-service-queued service) buffer-id)
      (cond
        [(recovery-snapshot? pending)
         (let ([buffer
                (package-host-buffer-ref
                  (recovery-service-host service) buffer-id #f)]
               [resource
                ((recovery-service-resource-for-buffer service) buffer-id)])
           (if (and buffer resource
                    (resource=? resource (recovery-snapshot-resource pending))
                    (history-modified? (recovery-service-history service) buffer-id))
               (let ([path (live-artifact-path service buffer-id)])
                 (vfs-create-directory! (recovery-service-directory service) #t)
                 (vfs-write-file
                   path
                   (encode-artifact
                     (recovery-snapshot-resource pending)
                     (recovery-snapshot-contents pending)))
                 (chmod path #o600))
               (clear-buffer-now! service buffer-id)))]
        [(eq? pending 'clear) (clear-buffer-now! service buffer-id)]
        [else #f])))

  (define (recovery-decision value)
    (let ([text (if (string? value) value
                    (if (symbol? value) (symbol->string value) ""))])
      (cond [(or (string-ci=? text "r") (string-ci=? text "recover")) 'recover]
            [(or (string-ci=? text "d") (string-ci=? text "discard")) 'discard]
            [(or (string-ci=? text "l") (string-ci=? text "later")) 'later]
            [else
             (assertion-violation 'recovery.restore
                                  "expected recover, discard, or later" value)])))

  (define (make-recovery-target-reader service)
    (make-interactive-reader
      'recovery-artifact
      (lambda (context arguments)
        (cond
          [(pair? arguments) (make-interactive-ready '())]
          [(null? (recovery-service-pending-artifacts service))
           (assertion-violation 'recovery.restore
                                "no recovery artifacts are available")]
          [(null? (cdr (recovery-service-pending-artifacts service)))
           (make-interactive-ready
             (list (car (recovery-service-pending-artifacts service))))]
          [else
           (let* ([artifacts (recovery-service-pending-artifacts service)]
                  [artifact-for
                   (lambda (value)
                     (find
                       (lambda (artifact)
                         (string=?
                           value (recovery-artifact-path artifact)))
                       artifacts))]
                  [source
                   (make-completion-source
                     (lambda (snapshot)
                       (map
                         (lambda (artifact)
                           (let ([path (recovery-artifact-path artifact)]
                                 [resource
                                  (resource-locator
                                    (recovery-artifact-resource artifact))])
                             (make-completion-candidate
                               path path resource path "recovery"
                               artifact)))
                         artifacts))
                     #f #f #f)])
             (make-interactive-suspend
               (make-interaction-request
                 'file-selection "Recover file: " #f source 'must-match
                 (lambda (value ignored)
                   (and (string? value) (artifact-for value))))
               (lambda (value)
                 (let ([artifact (and (string? value) (artifact-for value))])
                   (unless artifact
                     (assertion-violation 'recovery.restore
                                          "unknown recovery file" value))
                   (make-interactive-ready (list artifact))))))]))))

  (define (make-recovery-decision-reader)
    (make-interactive-reader
      'recovery-decision
      (lambda (context arguments)
        (let ([artifact (and (pair? arguments) (car arguments))])
          (unless (recovery-artifact? artifact)
            (assertion-violation 'recovery.restore
                                 "invalid recovery artifact" artifact))
          (make-interactive-suspend
            (make-interaction-request
              'recovery-decision
              (string-append
                "Recover unsaved contents for "
                (resource-locator (recovery-artifact-resource artifact))
                "? (recover/discard/later) ")
              #f #f 'free
              (lambda (value ignored)
                (guard (condition [else #f]) (recovery-decision value) #t))
              (list #\r #\d #\l))
            (lambda (value)
              (make-interactive-ready (list (recovery-decision value)))))))))

  (define (remove-pending-artifact! service artifact delete?)
    (recovery-service-pending-artifacts-set!
      service
      (filter (lambda (candidate) (not (eq? candidate artifact)))
              (recovery-service-pending-artifacts service)))
    (when delete? (delete-artifact! (recovery-artifact-path artifact))))

  (define (restore-artifact! service artifact context)
    (let* ([host (recovery-service-host service)]
           [state (command-context-buffer-state context)]
           [configuration
            (and state (buffer-state-configuration state))])
      (unless (and configuration
                   (command-context-surface-id context)
                   (command-context-window-id context))
        (assertion-violation 'recovery.restore
                             "recovery requires a routed Window context" context))
      (let* ([resource (recovery-artifact-resource artifact)]
             [buffer
              (package-host-create-buffer!
                host (recovery-service-owner service)
                (string-append "*recovered: " (resource-locator resource) "*")
                (make-document (recovery-artifact-contents artifact))
                configuration)]
             [view
              (package-host-create-view!
                host (recovery-service-owner service) buffer configuration)])
        (unless
          (package-host-replace-window-view!
            host (command-context-surface-id context)
            (command-context-window-id context) (view-id view))
          (package-host-close-buffer! host (buffer-id buffer))
          (assertion-violation 'recovery.restore
                               "origin Window is no longer available" context))
        (remove-pending-artifact! service artifact #t)
        buffer)))

  (define (handle-recovery-decision! service artifact decision context)
    (case decision
      [(recover) (restore-artifact! service artifact context)]
      [(discard) (remove-pending-artifact! service artifact #t)]
      [(later) #f]
      [else
       (assertion-violation 'recovery.restore
                            "unknown recovery decision" decision)]))

  (define make-recovery-service!
    (case-lambda
      [(host owner history resource-for-buffer)
       (make-recovery-service!
         host owner history resource-for-buffer (default-recovery-directory))]
      [(host owner history resource-for-buffer directory)
       (unless (and (package-host? host) (owner? owner) (history? history)
                    (procedure? resource-for-buffer)
                    (string? directory) (positive? (string-length directory)))
         (assertion-violation 'make-recovery-service!
                              "invalid recovery service dependencies"
                              host owner history directory))
       (owner-assert-active 'make-recovery-service! owner)
       (let* ([resolved
               (vfs-resolve-path
                 (vfs-directory-path (current-directory)) directory)]
              [service
               (%make-recovery-service
                 host owner history resource-for-buffer resolved
                 (make-eqv-hashtable) (make-eqv-hashtable)
                 (make-eqv-hashtable) (discover-artifacts resolved))]
              [runtime (package-host-command-runtime host)])
         (define-command
           runtime owner 'recovery.flush (context buffer-id)
           (documentation "Persist the latest coalesced recovery snapshot.")
           (class 'recovery)
           (undo 'ignore)
           (make-command-effect 'recovery.flush buffer-id))
         (command-runtime-register-effect-handler!
           runtime 'recovery.flush owner 'write-recovery-snapshot
           (lambda (ignored invocation effect)
             (flush-pending! service (command-effect-payload effect))))
         (define-command
           runtime owner 'recovery.restore (context artifact decision)
           (documentation "Recover, discard, or defer a recovery artifact.")
           (class 'recovery)
           (interactive
             (make-interactive-plan
               (list (make-recovery-target-reader service)
                     (make-recovery-decision-reader))))
           (undo 'ignore)
           (make-command-effect
             'recovery.restore (list artifact decision context)))
         (command-runtime-register-effect-handler!
           runtime 'recovery.restore owner 'restore-recovery-artifact
           (lambda (ignored invocation effect)
             (let ([payload (command-effect-payload effect)])
               (handle-recovery-decision!
                 service (car payload) (cadr payload) (caddr payload)))))
         (package-host-add-update-listener!
           host owner
           (lambda (update)
             (unless (change-set-empty? (editor-update-changes update))
               (let* ([buffer-id (editor-update-buffer-id update)]
                      [resource (resource-for-buffer buffer-id)]
                      [state (editor-update-new-buffer-state update)])
                 (cond
                   [(and resource (history-modified? history buffer-id))
                    (recovery-service-snapshot!
                      service buffer-id (buffer-state-generation state) resource
                      (snapshot-bytevector (buffer-state-document state)))]
                   [resource (queue-clear! service buffer-id)])))))
         service)]))
)
