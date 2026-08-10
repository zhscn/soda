(library (soda packages base fundamental-edit)
  (export replace-selection)
  (import (rnrs)
          (soda kernel change)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda packages base editing-context))

  (define (replace-selection context inserted)
    (unless (bytevector? inserted)
      (assertion-violation 'fundamental.insert-text "expected committed UTF-8 bytes" inserted))
    (let* ([selection (context-selection context)]
           [length (context-document-length context)]
           [changes
            (map
              (lambda (range)
                (make-text-change
                  (selection-range-from range) (selection-range-to range) inserted))
              (selection-ranges selection))]
           [change-set (make-change-set length changes)]
           [next-selection
            (make-selection
              (map
                (lambda (range)
                  (let ([position
                         (change-set-map-offset
                           change-set (selection-range-to range) 'after)])
                    (collapse-range range position)))
                (selection-ranges selection))
              (selection-primary selection))])
      (make-transaction-spec
        (command-context-buffer-id context)
        (command-context-view-id context)
        (buffer-state-generation (command-context-buffer-state context))
        change-set next-selection '() '())))
)

