(library (soda packages base history)
  (export make-history!
          history?
          history-mark-saved!
          history-modified?
          history-discard-buffer!)
  (import (rnrs)
          (soda kernel change) (soda kernel document) (soda kernel extension) (soda kernel state)
          (soda host command) (soda host command-runtime) (soda host dispatch)
          (soda host value))
  (define-record-type history-entry (fields undo redo))
  (define-record-type history
    (fields undo redo saved
            (mutable registration history-registration history-registration-set!)))
  (define (stack-ref table id) (hashtable-ref table id '()))

  (define (buffer-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  ;; A save point is the persistent undo-stack value at which the resource was
  ;; last synchronized.  Transactions retain their tail, so undo and redo can
  ;; return to the same save point without assigning document-specific state
  ;; to the kernel.
  (define (history-mark-saved! value buffer-id)
    (unless (and (history? value) (buffer-id? buffer-id))
      (assertion-violation 'history-mark-saved! "expected a history and Buffer id" value buffer-id))
    (hashtable-set! (history-saved value) buffer-id (stack-ref (history-undo value) buffer-id))
    #t)

  (define (history-modified? value buffer-id)
    (unless (and (history? value) (buffer-id? buffer-id))
      (assertion-violation 'history-modified? "expected a history and Buffer id" value buffer-id))
    (and (hashtable-contains? (history-saved value) buffer-id)
         (not (eq? (hashtable-ref (history-saved value) buffer-id #f)
                   (stack-ref (history-undo value) buffer-id)))))

  (define (history-discard-buffer! value buffer-id)
    (unless (and (history? value) (buffer-id? buffer-id))
      (assertion-violation 'history-discard-buffer! "expected a history and Buffer id" value buffer-id))
    (hashtable-set! (history-undo value) buffer-id '())
    (hashtable-set! (history-redo value) buffer-id '())
    (history-mark-saved! value buffer-id))
  (define (inverse update)
    (let ([changes (editor-update-changes update)]
          [old (editor-update-old-buffer-state update)])
      ;; ChangeSet owns the string/bytevector normalization and multi-range
      ;; coordinate mapping.  History must not reconstruct that protocol.
      (change-set-invert changes (snapshot-bytevector (buffer-state-document old)))))
  (define (replay context changes)
    (make-transaction-spec (command-context-buffer-id context) (command-context-view-id context)
                           (buffer-state-generation (command-context-buffer-state context))
                           changes #f '() (list (make-annotation 'history.replay #t)) #f #f))
  (define (install-history-command! runtime owner name doc procedure)
    (command-runtime-register-command! runtime
      (make-command-definition name procedure owner doc 'history #f)))
  (define (make-history! runtime dispatcher owner)
    (let ([value (make-history (make-eqv-hashtable) (make-eqv-hashtable)
                               (make-eqv-hashtable) #f)])
      (history-registration-set! value
        (dispatcher-add-listener! dispatcher owner
          (lambda (update)
            (let ([id (editor-update-buffer-id update)])
              (unless (exists (lambda (a) (eq? (annotation-key a) 'history.replay))
                              (editor-update-annotations update))
                (unless (change-set-empty? (editor-update-changes update))
                  ;; Buffers created after History are clean until their first
                  ;; transaction.  Capture that initial stack before pushing.
                  (unless (hashtable-contains? (history-saved value) id)
                    (history-mark-saved! value id))
                  (hashtable-set! (history-undo value) id
                    (cons (make-history-entry (inverse update) (editor-update-changes update))
                          (stack-ref (history-undo value) id)))
                  (hashtable-set! (history-redo value) id '())))))))
      (install-history-command! runtime owner 'history.undo "Undo the last Buffer transaction."
        (lambda (context)
          (let* ([id (command-context-buffer-id context)] [items (stack-ref (history-undo value) id)])
            (if (null? items) (command-handled)
                (begin (hashtable-set! (history-undo value) id (cdr items))
                       (hashtable-set! (history-redo value) id (cons (car items) (stack-ref (history-redo value) id)))
                       (replay context (history-entry-undo (car items))))))))
      (install-history-command! runtime owner 'history.redo "Redo the next Buffer transaction."
        (lambda (context)
          (let* ([id (command-context-buffer-id context)] [items (stack-ref (history-redo value) id)])
            (if (null? items) (command-handled)
                (begin (hashtable-set! (history-redo value) id (cdr items))
                       (hashtable-set! (history-undo value) id (cons (car items) (stack-ref (history-undo value) id)))
                       (replay context (history-entry-redo (car items))))))))
      value))
)
