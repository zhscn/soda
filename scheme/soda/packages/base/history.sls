(library (soda packages base history)
  (export make-history!)
  (import (rnrs)
          (soda kernel change) (soda kernel document) (soda kernel extension) (soda kernel state)
          (soda host command) (soda host command-runtime) (soda host dispatch)
          (soda host value))
  (define-record-type history-entry (fields undo redo))
  (define-record-type history
    (fields undo redo saved
            (mutable registration history-registration history-registration-set!)))
  (define (stack-ref table id) (hashtable-ref table id '()))
  (define (inverse update)
    (let* ([changes (editor-update-changes update)]
           [old (editor-update-old-buffer-state update)]
           [inverse-changes
            (map (lambda (change)
                   (let* ([from (change-set-map-offset changes (text-change-from change) 'before)]
                          [inserted (text-change-insert change)]
                          [to (+ from (bytevector-length inserted))])
                     (make-text-change from to
                       (snapshot-subbytevector (buffer-state-document old)
                                               (text-change-from change) (text-change-to change)))))
                 (change-set-changes changes))])
      (make-change-set (change-set-new-length changes) inverse-changes)))
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
