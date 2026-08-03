(library (soda core package)
  (export make-package-definition
          package-definition?
          package-definition-name
          package-definition-requires
          package-definition-provides
          package-definition-capabilities
          package-definition-activate
          package-definition-deactivate
          make-package-registry
          package-registry?
          register-package!
          package-definition-ref
          package-instance?
          package-instance-definition
          package-instance-owner
          package-instance-state
          package-instance-active?
          package-context?
          package-context-owner
          package-context-definition
          package-context-provide!
          package-context-service
          package-context-add-cleanup!
          package-activate!
          package-instance-ref
          package-instance-names
          package-deactivate!
          package-deactivate-all!
          package-deactivate-owner!)
  (import (rnrs)
          (soda core value))

  (define (unique-symbols? values)
    (let loop ([remaining values] [seen '()])
      (cond
        [(null? remaining) #t]
        [(memq (car remaining) seen) #f]
        [else (loop (cdr remaining) (cons (car remaining) seen))])))

  (define-record-type
    (package-definition %make-package-definition package-definition?)
    (fields
      (immutable name package-definition-name)
      (immutable requires package-definition-requires)
      (immutable provides package-definition-provides)
      (immutable capabilities package-definition-capabilities)
      (immutable activate package-definition-activate)
      (immutable deactivate package-definition-deactivate)))

  (define make-package-definition
    (case-lambda
      [(name requires provides activate)
       (make-package-definition name requires provides activate #f '())]
      [(name requires provides activate deactivate)
       (make-package-definition name requires provides activate deactivate '())]
      [(name requires provides activate deactivate capabilities)
      (unless (symbol? name)
        (assertion-violation
          'make-package-definition
          "name must be a symbol"
          name))
      (unless (and (list? requires)
                   (for-all symbol? requires)
                   (unique-symbols? requires))
        (assertion-violation
          'make-package-definition
          "requires must be a list of symbols"
          requires))
      (unless (and (list? provides)
                   (for-all symbol? provides)
                   (unique-symbols? provides))
        (assertion-violation
          'make-package-definition
          "provides must be a list of symbols"
          provides))
      (unless (procedure? activate)
        (assertion-violation
          'make-package-definition
          "activate must be a procedure"
          activate))
      (unless (or (not deactivate) (procedure? deactivate))
        (assertion-violation
          'make-package-definition
          "deactivate must be a procedure"
          deactivate))
      (unless (and (list? capabilities)
                   (for-all symbol? capabilities)
                   (unique-symbols? capabilities))
        (assertion-violation
          'make-package-definition
          "capabilities must be a list of symbols"
          capabilities))
      (%make-package-definition
        name
        requires
        provides
        capabilities
        activate
        deactivate)]))

  (define-record-type
    (package-context %make-package-context package-context?)
    (fields
      (immutable owner package-context-owner)
      (immutable definition package-context-definition)
      (immutable registry package-context-registry)
      (immutable services package-context-services)
      (mutable cleanups package-context-cleanups package-context-cleanups-set!)))

  (define (package-context-service value name . default)
    (unless (package-context? value)
      (assertion-violation
        'package-context-service
        "expected a package context"
        value))
    (let ([entry (assq name (package-context-services value))])
      (if entry
          (cdr entry)
          (if (null? default)
              (assertion-violation
                'package-context-service
                "service is not declared by a required package"
                name)
              (car default)))))

  (define (package-context-provide! value name service)
    (unless (package-context? value)
      (assertion-violation
        'package-context-provide!
        "expected a package context"
        value))
    (owner-assert-active
      'package-context-provide! (package-context-owner value))
    (unless (symbol? name)
      (assertion-violation
        'package-context-provide!
        "service name must be a symbol"
        name))
    (unless (memq name (package-definition-provides
                         (package-context-definition value)))
      (assertion-violation
        'package-context-provide!
        "service is not declared by the package"
        name))
    (let ([registry (package-context-registry value)])
      (when (hashtable-contains? (package-registry-services registry) name)
        (assertion-violation
          'package-context-provide!
          "service is already provided"
          name))
      (hashtable-set!
        (package-registry-services registry)
        name
        (cons (package-context-owner value) service))
      (package-context-add-cleanup!
        value
        (lambda ()
          (when (hashtable-contains?
                  (package-registry-services registry)
                  name)
            (let ([entry (hashtable-ref
                           (package-registry-services registry)
                           name
                           #f)])
              (when (eq? (car entry) (package-context-owner value))
                (hashtable-delete!
                  (package-registry-services registry)
                  name))))))
      service))

  (define (package-context-add-cleanup! value cleanup)
    (unless (package-context? value)
      (assertion-violation
        'package-context-add-cleanup!
        "expected a package context"
        value))
    (owner-assert-active
      'package-context-add-cleanup! (package-context-owner value))
    (unless (procedure? cleanup)
      (assertion-violation
        'package-context-add-cleanup!
        "cleanup must be a procedure"
        cleanup))
    (package-context-cleanups-set!
      value
      (cons cleanup (package-context-cleanups value)))
    cleanup)

  (define-record-type
    (package-instance %make-package-instance package-instance?)
    (fields
      (immutable definition package-instance-definition)
      (immutable owner package-instance-owner)
      (mutable state package-instance-state package-instance-state-set!)
      (mutable active? package-instance-active? package-instance-active?-set!)
      (immutable context package-instance-context)))

  (define-record-type
    (package-registry %make-package-registry package-registry?)
    (fields
      (immutable definitions package-registry-definitions)
      (immutable instances package-registry-instances)
      (immutable services package-registry-services)
      (immutable base-services package-registry-base-services)
      (mutable activation-stack package-registry-activation-stack
                package-registry-activation-stack-set!)))

  (define make-package-registry
    (case-lambda
      [() (make-package-registry '())]
      [(base-services)
       (unless (and (list? base-services)
                    (for-all
                      (lambda (entry)
                        (and (pair? entry) (symbol? (car entry))))
                      base-services)
                    (unique-symbols? (map car base-services)))
         (assertion-violation
           'make-package-registry "base services must be an alist"
           base-services))
       (%make-package-registry
         (make-eq-hashtable)
         (make-eq-hashtable)
         (make-eq-hashtable)
         base-services
         '())]))

  (define (register-package! registry definition)
    (unless (package-registry? registry)
      (assertion-violation
        'register-package!
        "expected a package registry"
        registry))
    (unless (package-definition? definition)
      (assertion-violation
        'register-package!
        "expected a package definition"
        definition))
    (for-each
      (lambda (service)
        (when (assq service (package-registry-base-services registry))
          (assertion-violation
            'register-package!
            "package service conflicts with a core capability"
            service)))
      (package-definition-provides definition))
    (let ([name (package-definition-name definition)])
      (when (hashtable-contains?
              (package-registry-definitions registry)
              name)
        (assertion-violation
          'register-package!
          "package is already registered"
          name))
      (hashtable-set!
        (package-registry-definitions registry)
        name
        definition)
      definition))

  (define (package-definition-ref registry name . default)
    (unless (package-registry? registry)
      (assertion-violation
        'package-definition-ref
        "expected a package registry"
        registry))
    (if (hashtable-contains? (package-registry-definitions registry) name)
        (hashtable-ref (package-registry-definitions registry) name #f)
        (if (null? default)
            (assertion-violation
              'package-definition-ref
              "package is not registered"
              name)
            (car default))))

  (define (package-instance-ref registry name . default)
    (unless (package-registry? registry)
      (assertion-violation
        'package-instance-ref
        "expected a package registry"
        registry))
    (if (hashtable-contains? (package-registry-instances registry) name)
        (hashtable-ref (package-registry-instances registry) name #f)
        (if (null? default) #f (car default))))

  (define (package-instance-names registry)
    (unless (package-registry? registry)
      (assertion-violation
        'package-instance-names
        "expected a package registry"
        registry))
    (call-with-values
      (lambda () (hashtable-entries (package-registry-instances registry)))
      (lambda (names instances)
        (vector->list names))))

  (define (run-cleanups! context)
    (let ([failure #f])
      (for-each
        (lambda (cleanup)
          (guard (condition [else (unless failure (set! failure condition))])
            (cleanup)))
        (package-context-cleanups context))
      (package-context-cleanups-set! context '())
      (when failure (raise failure))))

  (define (required-services registry definition)
    (let ([capabilities
            (map
              (lambda (name)
                (let ([entry (assq name (package-registry-base-services registry))])
                  (unless entry
                    (assertion-violation
                      'package-activate! "unknown core capability" name))
                  entry))
              (package-definition-capabilities definition))])
      (fold-left
      (lambda (result dependency)
        (let* ([instance (package-instance-ref registry dependency)]
               [owner (package-instance-owner instance)])
          (fold-left
            (lambda (services name)
              (let ([entry
                      (hashtable-ref
                        (package-registry-services registry) name #f)])
                (unless (and entry (eq? owner (car entry)))
                  (assertion-violation
                    'package-activate!
                    "required package did not provide its declared service"
                    dependency name))
                (cons (cons name (cdr entry)) services)))
            result
            (package-definition-provides
              (package-instance-definition instance)))))
        capabilities
        (package-definition-requires definition))))

  (define (validate-provided-services! registry context)
    (for-each
      (lambda (name)
        (let ([entry
                (hashtable-ref (package-registry-services registry) name #f)])
          (unless (and entry
                       (eq? (car entry) (package-context-owner context)))
            (assertion-violation
              'package-activate!
              "package did not provide its declared service"
              (package-definition-name (package-context-definition context))
              name))))
      (package-definition-provides (package-context-definition context))))

  (define (package-deactivate-owner! instance)
    (unless (package-instance? instance)
      (assertion-violation
        'package-deactivate-owner!
        "expected a package instance"
        instance))
    (when (package-instance-active? instance)
      (let* ([definition (package-instance-definition instance)]
             [context (package-instance-context instance)]
             [deactivate (package-definition-deactivate definition)]
             [failure #f])
        (when deactivate
          (guard (condition [else (set! failure condition)])
            (deactivate context (package-instance-state instance))))
        (guard (condition [else (unless failure (set! failure condition))])
          (run-cleanups! context))
        (guard (condition [else (unless failure (set! failure condition))])
          (owner-close! (package-instance-owner instance)))
        (package-instance-active?-set! instance #f)
        (package-instance-state-set! instance #f)
        (when failure (raise failure))))
    #t)

  (define (package-activate! registry name)
    (unless (package-registry? registry)
      (assertion-violation
        'package-activate!
        "expected a package registry"
        registry))
    (let ([existing (package-instance-ref registry name)])
      (if existing
          (if (package-instance-active? existing)
              existing
              (begin
                (hashtable-delete! (package-registry-instances registry) name)
                (package-activate! registry name)))
          (let ([definition (package-definition-ref registry name)])
            (when (memq name (package-registry-activation-stack registry))
              (assertion-violation
                'package-activate!
                "cyclic package dependency"
                name))
            (package-registry-activation-stack-set!
              registry
              (cons name (package-registry-activation-stack registry)))
            (guard
              (condition [else
                          (package-registry-activation-stack-set!
                            registry
                            (cdr (package-registry-activation-stack registry)))
                          (raise condition)])
              (for-each
                (lambda (dependency)
                  (package-activate! registry dependency))
                (package-definition-requires definition))
              (let* ([owner (make-owner name)]
                     [context
                       (%make-package-context
                         owner
                         definition
                         registry
                         (required-services registry definition)
                         '())]
                     [state
                       (guard
                         (condition [else
                                     (guard (cleanup-condition [else #f])
                                       (run-cleanups! context))
                                     (guard (cleanup-condition [else #f])
                                       (owner-close! owner))
                                     (raise condition)])
                         (let ([state
                                 ((package-definition-activate definition)
                                  context)])
                           (validate-provided-services! registry context)
                           state))]
                     [instance
                       (%make-package-instance
                         definition owner state #t context)])
                (hashtable-set!
                  (package-registry-instances registry)
                  name
                  instance)
                (package-registry-activation-stack-set!
                  registry
                  (cdr (package-registry-activation-stack registry)))
                instance))))))

  (define (package-deactivate! registry name)
    (unless (package-registry? registry)
      (assertion-violation
        'package-deactivate!
        "expected a package registry"
        registry))
    (let ([instance (package-instance-ref registry name)])
      (if instance
          (let ([dependent
                  (find
                    (lambda (candidate)
                      (and
                        (not (eq? candidate name))
                        (let ([candidate-instance
                                (package-instance-ref registry candidate)])
                          (and candidate-instance
                               (memq
                                 name
                                 (package-definition-requires
                                   (package-instance-definition
                                     candidate-instance)))))))
                    (package-instance-names registry))])
            (when dependent
              (assertion-violation
                'package-deactivate!
                "package has active dependents"
                name
                dependent))
            (guard
              (condition
                [else
                 (hashtable-delete!
                   (package-registry-instances registry) name)
                 (raise condition)])
              (package-deactivate-owner! instance)
              (hashtable-delete!
                (package-registry-instances registry)
                name)
              #t))
          #f)))

  (define (package-active-dependent registry name names)
    (find
      (lambda (candidate)
        (and (not (eq? candidate name))
             (let ([instance (package-instance-ref registry candidate)])
               (and instance
                    (package-instance-active? instance)
                    (memq
                      name
                      (package-definition-requires
                        (package-instance-definition instance)))))))
      names))

  (define (package-deactivate-all! registry)
    (unless (package-registry? registry)
      (assertion-violation
        'package-deactivate-all!
        "expected a package registry"
        registry))
    (let ([failure #f])
      (let loop ([remaining (package-instance-names registry)])
      (if (null? remaining)
          (if failure (raise failure) #t)
          (let ([name
                  (find
                    (lambda (candidate)
                      (not (package-active-dependent
                             registry candidate remaining)))
                    remaining)])
            (unless name
              (assertion-violation
                'package-deactivate-all!
                "package dependency graph could not be unloaded"
                remaining))
            (guard
              (condition [else (unless failure (set! failure condition))])
              (package-deactivate! registry name))
            (loop (filter
                    (lambda (candidate) (not (eq? candidate name)))
                    remaining)))))))
)
