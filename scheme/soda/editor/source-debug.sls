(library (soda editor source-debug)
  (export make-source-location
          source-location?
          source-location-resource
          source-location-start
          source-location-end
          make-source-debug-controller
          source-debug-controller?
          source-debug-controller-breakpoints
          source-debug-controller-add-breakpoint!
          source-debug-controller-remove-breakpoint!
          source-debug-controller-toggle-breakpoint!
          source-debug-controller-matching-breakpoint
          source-breakpoint?
          source-breakpoint-id
          source-breakpoint-location
          source-breakpoint-enabled?
          source-breakpoint-set-enabled!
          make-source-debug-plan
          source-debug-plan?
          source-debug-plan-kind
          source-debug-plan-location
          source-debug-plan-depth
          make-source-debug-stop
          source-debug-stop?
          source-debug-stop-kind
          source-debug-stop-location
          source-debug-stop-depth
          source-debug-stop-continuation
          source-debug-stop-breakpoint
          make-source-debug-suspension-condition
          source-debug-suspension-condition?
          source-debug-suspension-stop
          source-debug-instrument)
  (import (chezscheme))

  (define-record-type
    (source-location
      %make-source-location
      source-location?)
    (fields resource start end))

  (define-record-type
    (source-breakpoint
      %make-source-breakpoint
      source-breakpoint?)
    (fields
      id
      location
      (mutable enabled?
               source-breakpoint-enabled?
               source-breakpoint-enabled?-set!)))

  (define-record-type
    (source-debug-controller
      %make-source-debug-controller
      source-debug-controller?)
    (fields
      (mutable next-id
               source-debug-controller-next-id
               source-debug-controller-next-id-set!)
      (mutable breakpoints
               source-debug-controller-breakpoints
               source-debug-controller-breakpoints-set!)))

  (define-record-type
    (source-debug-plan
      %make-source-debug-plan
      source-debug-plan?)
    (fields kind location depth))

  (define-record-type
    (source-debug-stop
      %make-source-debug-stop
      source-debug-stop?)
    (fields kind location depth continuation breakpoint))

  (define-condition-type
    &source-debug-suspension
    &condition
    make-source-debug-suspension-condition
    source-debug-suspension-condition?
    (stop source-debug-suspension-stop))

  (define (require-location who location)
    (unless (source-location? location)
      (assertion-violation
        who
        "expected a source location"
        location))
    location)

  (define (make-source-location resource start end)
    (unless resource
      (assertion-violation
        'make-source-location
        "source location requires a resource"))
    (unless
      (and
        (integer? start)
        (exact? start)
        (not (negative? start))
        (integer? end)
        (exact? end)
        (> end start))
      (assertion-violation
        'make-source-location
        "source location requires a non-empty byte range"
        start
        end))
    (%make-source-location resource start end))

  (define (make-source-debug-controller)
    (%make-source-debug-controller 0 '()))

  (define (same-source-range? left right)
    (and
      (equal?
        (source-location-resource left)
        (source-location-resource right))
      (= (source-location-start left)
         (source-location-start right))
      (= (source-location-end left)
         (source-location-end right))))

  (define (source-debug-controller-add-breakpoint!
            controller
            location)
    (unless (source-debug-controller? controller)
      (assertion-violation
        'source-debug-controller-add-breakpoint!
        "expected a source debugger controller"
        controller))
    (require-location
      'source-debug-controller-add-breakpoint!
      location)
    (or
      (find
        (lambda (breakpoint)
          (same-source-range?
            location
            (source-breakpoint-location breakpoint)))
        (source-debug-controller-breakpoints controller))
      (let* ([id
               (source-debug-controller-next-id controller)]
             [breakpoint
               (%make-source-breakpoint id location #t)])
        (source-debug-controller-next-id-set!
          controller
          (+ id 1))
        (source-debug-controller-breakpoints-set!
          controller
          (append
            (source-debug-controller-breakpoints controller)
            (list breakpoint)))
        breakpoint)))

  (define (source-debug-controller-remove-breakpoint!
            controller
            id)
    (unless (source-debug-controller? controller)
      (assertion-violation
        'source-debug-controller-remove-breakpoint!
        "expected a source debugger controller"
        controller))
    (unless
      (and
        (integer? id)
        (exact? id)
        (not (negative? id)))
      (assertion-violation
        'source-debug-controller-remove-breakpoint!
        "breakpoint id must be a non-negative exact integer"
        id))
    (let ([before
            (source-debug-controller-breakpoints controller)])
      (let ([after
              (filter
                (lambda (breakpoint)
                  (not (= id (source-breakpoint-id breakpoint))))
                before)])
        (source-debug-controller-breakpoints-set!
          controller
          after)
        (< (length after) (length before)))))

  (define (source-debug-controller-toggle-breakpoint!
            controller
            location)
    (unless (source-debug-controller? controller)
      (assertion-violation
        'source-debug-controller-toggle-breakpoint!
        "expected a source debugger controller"
        controller))
    (require-location
      'source-debug-controller-toggle-breakpoint!
      location)
    (let ([existing
            (find
              (lambda (breakpoint)
                (same-source-range?
                  location
                  (source-breakpoint-location breakpoint)))
              (source-debug-controller-breakpoints controller))])
      (if existing
          (begin
            (source-debug-controller-remove-breakpoint!
              controller
              (source-breakpoint-id existing))
            #f)
          (source-debug-controller-add-breakpoint!
            controller
            location))))

  (define (source-breakpoint-set-enabled!
            breakpoint
            enabled?)
    (unless (source-breakpoint? breakpoint)
      (assertion-violation
        'source-breakpoint-set-enabled!
        "expected a source breakpoint"
        breakpoint))
    (unless (boolean? enabled?)
      (assertion-violation
        'source-breakpoint-set-enabled!
        "enabled state must be boolean"
        enabled?))
    (source-breakpoint-enabled?-set!
      breakpoint
      enabled?)
    enabled?)

  (define (location-starts-in? location range)
    (and
      (equal?
        (source-location-resource location)
        (source-location-resource range))
      (<=
        (source-location-start range)
        (source-location-start location))
      (<
        (source-location-start location)
        (source-location-end range))))

  (define (source-debug-controller-matching-breakpoint
            controller
            location)
    (unless (source-debug-controller? controller)
      (assertion-violation
        'source-debug-controller-matching-breakpoint
        "expected a source debugger controller"
        controller))
    (require-location
      'source-debug-controller-matching-breakpoint
      location)
    (find
      (lambda (breakpoint)
        (and
          (source-breakpoint-enabled? breakpoint)
          (location-starts-in?
            location
            (source-breakpoint-location breakpoint))))
      (source-debug-controller-breakpoints controller)))

  (define (make-source-debug-plan kind location depth)
    (unless (memq kind '(step next finish))
      (assertion-violation
        'make-source-debug-plan
        "source debug plan must be step, next, or finish"
        kind))
    (require-location 'make-source-debug-plan location)
    (unless
      (and
        (integer? depth)
        (exact? depth)
        (not (negative? depth)))
      (assertion-violation
        'make-source-debug-plan
        "source debug depth must be a non-negative exact integer"
        depth))
    (%make-source-debug-plan kind location depth))

  (define (make-source-debug-stop
            kind
            location
            depth
            continuation
            breakpoint)
    (unless (memq kind '(breakpoint step next finish))
      (assertion-violation
        'make-source-debug-stop
        "source debug stop has an invalid kind"
        kind))
    (require-location 'make-source-debug-stop location)
    (unless
      (and
        (integer? depth)
        (exact? depth)
        (not (negative? depth)))
      (assertion-violation
        'make-source-debug-stop
        "source debug depth must be a non-negative exact integer"
        depth))
    (unless (procedure? continuation)
      (assertion-violation
        'make-source-debug-stop
        "source debug stop requires a continuation"
        continuation))
    (unless
      (or (not breakpoint) (source-breakpoint? breakpoint))
      (assertion-violation
        'make-source-debug-stop
        "source debug stop breakpoint is invalid"
        breakpoint))
    (%make-source-debug-stop
      kind
      location
      depth
      continuation
      breakpoint))

  (define (strip-annotations value)
    (cond
      [(annotation? value)
       (strip-annotations
         (annotation-expression value))]
      [(pair? value)
       (cons
         (strip-annotations (car value))
         (strip-annotations (cdr value)))]
      [(vector? value)
       (vector-map strip-annotations value)]
      [else value]))

  (define (annotation-location annotation resource)
    (let ([source (annotation-source annotation)])
      (make-source-location
        resource
        (source-object-bfp source)
        (source-object-efp source))))

  (define (head-symbol value)
    (let ([datum
            (if (annotation? value)
                (annotation-expression value)
                value)])
      (and
        (pair? datum)
        (let ([head
                (strip-annotations (car datum))])
          (and (symbol? head) head)))))

  (define (instrument-body body resource probe)
    (map
      (lambda (expression)
        (instrument-expression
          expression
          resource
          probe))
      body))

  (define (instrument-bindings bindings resource probe)
    (map
      (lambda (binding)
        (let ([parts
                (strip-annotations binding)])
          (if
            (and (pair? parts) (pair? (cdr parts)))
            (cons
              (car parts)
              (cons
                (instrument-expression
                  (cadr
                    (if (annotation? binding)
                        (annotation-expression binding)
                        binding))
                  resource
                  probe)
                (cddr parts)))
            parts)))
      (let ([value
              (if (annotation? bindings)
                  (annotation-expression bindings)
                  bindings)])
        value)))

  (define (wrap-probe core annotation resource probe)
    (if annotation
        (let ([location
                (annotation-location annotation resource)])
          (list
            'begin
            (list
              probe
              (list
                'quote
                (source-location-resource location))
              (source-location-start location)
              (source-location-end location))
            core))
        core))

  (define (instrument-expression value resource probe)
    (let* ([annotation
             (and (annotation? value) value)]
           [expression
             (if annotation
                 (annotation-expression annotation)
                 value)]
           [plain (strip-annotations expression)]
           [head (head-symbol expression)])
      (cond
        [(not (pair? plain)) plain]
        [(memq head
           '(quote quasiquote syntax quasisyntax
              import export library module
              define-syntax let-syntax letrec-syntax))
         plain]
        [(eq? head 'lambda)
         (cons
           'lambda
           (cons
             (cadr plain)
             (instrument-body
               (cddr expression)
               resource
               probe)))]
        [(eq? head 'case-lambda)
         (cons
           'case-lambda
           (map
             (lambda (clause)
               (let ([parts
                       (if (annotation? clause)
                           (annotation-expression clause)
                           clause)])
                 (cons
                   (strip-annotations (car parts))
                   (instrument-body
                     (cdr parts)
                     resource
                     probe))))
             (cdr expression)))]
        [(eq? head 'define)
         (if (pair? (cadr plain))
             (cons
               'define
               (cons
                 (cadr plain)
                 (instrument-body
                   (cddr expression)
                   resource
                   probe)))
             (list
               'define
               (cadr plain)
               (instrument-expression
                 (caddr expression)
                 resource
                 probe)))]
        [(eq? head 'if)
         (wrap-probe
           (cons
             'if
             (instrument-body
               (cdr expression)
               resource
               probe))
           annotation
           resource
           probe)]
        [(eq? head 'begin)
         (wrap-probe
           (cons
             'begin
             (instrument-body
               (cdr expression)
               resource
               probe))
           annotation
           resource
           probe)]
        [(memq head '(let let* letrec letrec*))
         (let* ([tail (cdr expression)]
                [named?
                  (and
                    (pair? tail)
                    (symbol?
                      (strip-annotations
                        (car tail))))]
                [name
                  (and named?
                       (strip-annotations (car tail)))]
                [bindings
                  (if named? (cadr tail) (car tail))]
                [body
                  (if named? (cddr tail) (cdr tail))])
           (wrap-probe
             (append
               (list head)
               (if named? (list name) '())
               (list
                 (instrument-bindings
                   bindings
                   resource
                   probe))
               (instrument-body body resource probe))
             annotation
             resource
             probe))]
        [(eq? head 'set!)
         (wrap-probe
           (list
             'set!
             (cadr plain)
             (instrument-expression
               (caddr expression)
               resource
               probe))
           annotation
           resource
           probe)]
        [(memq head '(and or when unless))
         (wrap-probe
           (cons
             head
             (instrument-body
               (cdr expression)
               resource
               probe))
           annotation
           resource
           probe)]
        [else
         (wrap-probe
           plain
           annotation
           resource
           probe)])))

  (define (source-debug-instrument
            annotated-datum
            resource
            probe)
    (unless (annotation? annotated-datum)
      (assertion-violation
        'source-debug-instrument
        "expected an annotated datum"
        annotated-datum))
    (unless resource
      (assertion-violation
        'source-debug-instrument
        "source instrumentation requires a resource"))
    (unless (symbol? probe)
      (assertion-violation
        'source-debug-instrument
        "probe binding must be a symbol"
        probe))
    (instrument-expression
      annotated-datum
      resource
      probe))
)
