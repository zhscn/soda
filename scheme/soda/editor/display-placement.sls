(library (soda editor display-placement)
  (export make-display-request
          display-request?
          display-request-buffer-id
          display-request-intent
          display-request-origin-view-id
          display-request-target-window-id
          display-request-resource-context
          make-display-plan
          display-plan?
          display-plan-workbench-id
          display-plan-window-id
          display-plan-action
          display-plan-role
          editor-plan-display
          editor-display-buffer!)
  (import (rnrs)
          (soda editor contract)
          (soda editor buffer)
          (soda editor resource-context)
          (soda editor state)
          (soda editor language-state)
          (soda editor window)
          (soda editor workbench))

  (define display-intents '(edit jump tools doc pop explicit))

  (define-record-type
    (display-request %make-display-request display-request?)
    (fields buffer-id
            intent
            origin-view-id
            target-window-id
            resource-context))

  (define-record-type
    (display-plan %make-display-plan display-plan?)
    (fields workbench-id window-id action role))

  (define (make-display-request
            buffer-id intent origin-view-id target-window-id context)
    (unless (exact-positive-integer? buffer-id)
      (assertion-violation
        'make-display-request
        "Buffer id must be a positive exact integer"
        buffer-id))
    (unless (memq intent display-intents)
      (assertion-violation
        'make-display-request
        "unknown display intent"
        intent))
    (unless
      (or (not origin-view-id)
          (exact-positive-integer? origin-view-id))
      (assertion-violation
        'make-display-request
        "origin View id must be a positive exact integer or #f"
        origin-view-id))
    (unless
      (or (not target-window-id)
          (exact-positive-integer? target-window-id))
      (assertion-violation
        'make-display-request
        "target Window id must be a positive exact integer or #f"
        target-window-id))
    (when
      (and (eq? intent 'explicit) (not target-window-id))
      (assertion-violation
        'make-display-request
        "explicit placement requires a target Window"))
    (when
      (and target-window-id (not (eq? intent 'explicit)))
      (assertion-violation
        'make-display-request
        "only explicit placement accepts a target Window"
        intent
        target-window-id))
    (unless (or (not context) (resource-context? context))
      (assertion-violation
        'make-display-request
        "resource context must be a ResourceContext or #f"
        context))
    (%make-display-request
      buffer-id intent origin-view-id target-window-id context))

  (define (make-display-plan workbench-id window-id action role)
    (unless (and
              (exact-positive-integer? workbench-id)
              (exact-positive-integer? window-id))
      (assertion-violation
        'make-display-plan
        "Workbench and Window ids must be positive exact integers"
        workbench-id
        window-id))
    (unless (memq action '(reuse replace split))
      (assertion-violation
        'make-display-plan
        "unknown placement action"
        action))
    (unless (or (not role) (symbol? role))
      (assertion-violation
        'make-display-plan
        "role must be a symbol or #f"
        role))
    (%make-display-plan workbench-id window-id action role))

  (define (workbench-window-for-view workbench view-id)
    (find
      (lambda (leaf) (= (window-leaf-view-id leaf) view-id))
      (window-node-leaves (workbench-layout workbench))))

  (define (workbench-for-window editor window-id)
    (find
      (lambda (workbench)
        (window-node-find (workbench-layout workbench) window-id))
      (editor-workbenches editor)))

  (define (origin-workbench editor origin-view-id)
    (and
      origin-view-id
      (guard (condition [else #f])
        (editor-workbench-for-view editor origin-view-id))))

  (define (buffer-window editor workbench target-buffer-id)
    (find
      (lambda (leaf)
        (=
          (buffer-id
            (view-buffer
              (editor-view-ref
                editor
                (window-leaf-view-id leaf))))
          target-buffer-id))
      (window-node-leaves (workbench-layout workbench))))

  (define (intent-role intent)
    (and (memq intent '(jump tools doc)) intent))

  (define (editor-plan-display editor request)
    (unless (display-request? request)
      (assertion-violation
        'editor-plan-display
        "expected a display request"
        request))
    (editor-buffer-ref editor (display-request-buffer-id request))
    (let* ([intent (display-request-intent request)]
           [explicit-window
             (display-request-target-window-id request)]
           [workbench
             (if explicit-window
                 (or
                   (workbench-for-window editor explicit-window)
                   (assertion-violation
                     'editor-plan-display
                     "target Window is not owned by a Workbench"
                     explicit-window))
                 (or
                   (origin-workbench
                     editor
                     (display-request-origin-view-id request))
                   (editor-active-workbench editor)))]
           [existing
             (and
               (not (eq? intent 'pop))
               (not (eq? intent 'explicit))
               (buffer-window
                 editor
                 workbench
                 (display-request-buffer-id request)))]
           [role (intent-role intent)]
           [slot-window-id
             (and role (workbench-slot-window-id workbench role))]
           [target-window-id
             (or
               explicit-window
               (and existing (window-leaf-id existing))
               slot-window-id
               (workbench-active-window-id workbench))]
           [pinned?
             (workbench-window-pinned?
               workbench
               target-window-id)]
           [target-role
             (workbench-window-role workbench target-window-id)]
           [action
             (cond
               [existing 'reuse]
               [(eq? intent 'pop) 'split]
               [(eq? intent 'explicit) 'replace]
               [pinned? 'split]
               [slot-window-id 'replace]
               [(eq? intent 'edit) 'replace]
               [(and
                  (eq? intent 'jump)
                  (not target-role))
                'replace]
               [else 'split])]
           [plan-role
             (and
               role
               (not slot-window-id)
               (memq action '(replace split))
               role)])
      (make-display-plan
        (workbench-id workbench)
        target-window-id
        action
        plan-role)))

  (define (request-context editor request)
    (or
      (display-request-resource-context request)
      (let ([origin (display-request-origin-view-id request)])
        (and
          origin
          (guard (condition [else #f])
            (editor-view-resource-context editor origin))))
      (editor-view-resource-context
        editor
        (view-id (editor-active-view editor)))))

  (define (replace-window-buffer! editor workbench window-id request)
    (let* ([leaf
             (window-node-find (workbench-layout workbench) window-id)]
           [view-id (window-leaf-view-id leaf)])
      (editor-set-view-buffer!
        editor
        view-id
        (display-request-buffer-id request))
      (editor-set-view-resource-context!
        editor
        view-id
        (request-context editor request))
      (values leaf (editor-view-ref editor view-id))))

  (define (split-window-with-buffer! editor workbench window-id request role)
    (let* ([view
             (editor-open-view!
               editor
               (display-request-buffer-id request)
               (request-context editor request))]
           [leaf
             (make-window-leaf
               (editor-allocate-window-id! editor)
               (view-id view))]
           [split
             (make-window-split
               (editor-allocate-window-id! editor)
               'vertical
               (list
                 (window-node-find
                   (workbench-layout workbench)
                   window-id)
                 leaf))]
           [layout
             (window-node-replace
               (workbench-layout workbench)
               window-id
               split)])
      (if
        (eq? workbench (editor-active-workbench editor))
        (editor-set-window-root! editor layout)
        (editor-set-workbench-layout!
          editor (workbench-id workbench) layout))
      (when role
        (workbench-set-slot!
          workbench
          role
          (window-leaf-id leaf)))
      (values leaf view)))

  (define (activate-placement! editor workbench leaf view)
    (when (eq? workbench (editor-active-workbench editor))
      (editor-set-active-window-id!
        editor
        (window-leaf-id leaf))
      (editor-set-active-view! editor (view-id view))))

  (define (editor-display-buffer! editor request)
    (let* ([plan (editor-plan-display editor request)]
           [workbench
             (editor-workbench-ref
               editor
               (display-plan-workbench-id plan))])
      (case (display-plan-action plan)
        [(reuse)
         (let* ([leaf
                  (window-node-find
                    (workbench-layout workbench)
                    (display-plan-window-id plan))]
                [view
                  (editor-view-ref
                    editor
                    (window-leaf-view-id leaf))])
           (editor-set-view-resource-context!
             editor
             (view-id view)
             (request-context editor request))
           (activate-placement! editor workbench leaf view)
           view)]
        [(replace)
         (call-with-values
           (lambda ()
             (replace-window-buffer!
               editor
               workbench
               (display-plan-window-id plan)
               request))
           (lambda (leaf view)
             (when (display-plan-role plan)
               (workbench-set-slot!
                 workbench
                 (display-plan-role plan)
                 (window-leaf-id leaf)))
             (activate-placement! editor workbench leaf view)
             view))]
        [(split)
         (call-with-values
           (lambda ()
             (split-window-with-buffer!
               editor
               workbench
               (display-plan-window-id plan)
               request
               (display-plan-role plan)))
           (lambda (leaf view)
             (activate-placement! editor workbench leaf view)
             view))])))
)
