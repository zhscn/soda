(library (soda editor xref)
  (export make-xref-backend
          xref-backend?
          xref-backend-name
          editor-register-xref-backend!
          dispatch-xref
          install-xref-results!
          editor-show-xref-results!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor command)
          (soda editor condition)
          (soda editor location-results))

  (define editor-xref-backends
    (make-weak-eq-hashtable))

  (define-record-type (xref-backend %make-xref-backend xref-backend?)
    (fields name priority applicable? definitions references))

  (define (make-xref-backend
            name priority applicable? definitions references)
    (unless (symbol? name)
      (assertion-violation 'make-xref-backend "name must be a symbol" name))
    (unless (and (integer? priority) (exact? priority))
      (assertion-violation
        'make-xref-backend "priority must be an exact integer" priority))
    (unless (and (procedure? applicable?)
                 (procedure? definitions)
                 (procedure? references))
      (assertion-violation
        'make-xref-backend
        "backend operations must be procedures"
        applicable? definitions references))
    (%make-xref-backend name priority applicable? definitions references))

  (define (editor-register-xref-backend! editor backend)
    (unless (xref-backend? backend)
      (assertion-violation
        'editor-register-xref-backend! "expected an xref backend" backend))
    (let* ([current (hashtable-ref editor-xref-backends editor '())]
           [without
             (filter
               (lambda (item)
                 (not (eq? (xref-backend-name item) (xref-backend-name backend))))
               current)])
      (hashtable-set!
        editor-xref-backends
        editor
        (list-sort
          (lambda (left right)
            (> (xref-backend-priority left) (xref-backend-priority right)))
          (cons backend without))))
    backend)

  (define (xref-backend-for-context context)
    (find
      (lambda (backend) ((xref-backend-applicable? backend) context))
      (hashtable-ref
        editor-xref-backends
        (command-context-editor context)
        '())))

  (define (dispatch-xref context operation)
    (let ([backend (xref-backend-for-context context)])
      (unless backend
        (editor-user-error operation "No xref backend is available for this Buffer"))
      ((case operation
         [(xref.find-definition) (xref-backend-definitions backend)]
         [(xref.find-references) (xref-backend-references backend)]
         [else
          (assertion-violation 'dispatch-xref "unknown xref operation" operation)])
       context)))

  (define (install-xref-results! editor)
    (install-location-results! editor))

  (define (editor-show-xref-results! editor locations origin-view-id)
    (editor-show-location-results!
      editor "References" locations origin-view-id 'xref))
)
