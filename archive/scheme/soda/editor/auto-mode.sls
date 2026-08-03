(library (soda editor auto-mode)
  (export make-auto-mode-rule
          make-file-suffix-auto-mode-rule
          auto-mode-rule?
          auto-mode-rule-name
          auto-mode-rule-priority
          auto-mode-rule-matcher
          auto-mode-rule-major-mode
          make-auto-mode-catalog
          auto-mode-catalog?
          auto-mode-catalog-generation
          auto-mode-catalog-register!
          auto-mode-catalog-remove!
          auto-mode-catalog-find
          auto-mode-catalog-rules
          auto-mode-catalog-resolve
          auto-mode-catalog-snapshot
          auto-mode-catalog-restore!)
  (import (rnrs)
          (soda editor string))

  (define-record-type
    (auto-mode-rule %make-auto-mode-rule auto-mode-rule?)
    (fields name priority matcher major-mode))

  (define-record-type
    (auto-mode-catalog %make-auto-mode-catalog auto-mode-catalog?)
    (fields
      (mutable rules auto-mode-catalog-rules auto-mode-catalog-rules-set!)
      (mutable generation
               auto-mode-catalog-generation
               auto-mode-catalog-generation-set!)))

  (define-record-type
    (auto-mode-catalog-state
      %make-auto-mode-catalog-state
      auto-mode-catalog-state?)
    (fields rules generation))

  (define (make-auto-mode-rule name priority matcher major-mode)
    (unless (symbol? name)
      (assertion-violation
        'make-auto-mode-rule
        "name must be a symbol"
        name))
    (unless (and (integer? priority) (exact? priority))
      (assertion-violation
        'make-auto-mode-rule
        "priority must be an exact integer"
        priority))
    (unless (procedure? matcher)
      (assertion-violation
        'make-auto-mode-rule
        "matcher must be a procedure"
        matcher))
    (unless (symbol? major-mode)
      (assertion-violation
        'make-auto-mode-rule
        "major mode must be a symbol"
        major-mode))
    (%make-auto-mode-rule name priority matcher major-mode))

  (define (make-file-suffix-auto-mode-rule
            name
            priority
            suffixes
            major-mode)
    (unless
      (and
        (list? suffixes)
        (pair? suffixes)
        (for-all
          (lambda (suffix)
            (and (string? suffix)
                 (positive? (string-length suffix))))
          suffixes))
      (assertion-violation
        'make-file-suffix-auto-mode-rule
        "suffixes must be a non-empty list of non-empty strings"
        suffixes))
    (let ([normalized (map string-foldcase suffixes)])
      (make-auto-mode-rule
        name
        priority
        (lambda (path)
          (and
            (string? path)
            (let ([candidate (string-foldcase path)])
              (exists
                (lambda (suffix)
                  (string-suffix? suffix candidate))
                normalized))))
        major-mode)))

  (define (make-auto-mode-catalog)
    (%make-auto-mode-catalog '() 0))

  (define (require-catalog who catalog)
    (unless (auto-mode-catalog? catalog)
      (assertion-violation
        who
        "expected an auto mode catalog"
        catalog)))

  (define (insert-rule rule rules)
    (cond
      [(null? rules) (list rule)]
      [(> (auto-mode-rule-priority rule)
          (auto-mode-rule-priority (car rules)))
       (cons rule rules)]
      [else
       (cons (car rules) (insert-rule rule (cdr rules)))]))

  (define (auto-mode-catalog-register! catalog rule)
    (require-catalog 'auto-mode-catalog-register! catalog)
    (unless (auto-mode-rule? rule)
      (assertion-violation
        'auto-mode-catalog-register!
        "expected an auto mode rule"
        rule))
    (auto-mode-catalog-rules-set!
      catalog
      (insert-rule
        rule
        (filter
          (lambda (existing)
            (not
              (eq?
                (auto-mode-rule-name existing)
                (auto-mode-rule-name rule))))
          (auto-mode-catalog-rules catalog))))
    (auto-mode-catalog-generation-set!
      catalog
      (+ (auto-mode-catalog-generation catalog) 1))
    rule)

  (define (auto-mode-catalog-find catalog name)
    (require-catalog 'auto-mode-catalog-find catalog)
    (unless (symbol? name)
      (assertion-violation
        'auto-mode-catalog-find
        "rule name must be a symbol"
        name))
    (find
      (lambda (rule) (eq? (auto-mode-rule-name rule) name))
      (auto-mode-catalog-rules catalog)))

  (define (auto-mode-catalog-remove! catalog name)
    (require-catalog 'auto-mode-catalog-remove! catalog)
    (let ([existing (auto-mode-catalog-find catalog name)])
      (when existing
        (auto-mode-catalog-rules-set!
          catalog
          (remq existing (auto-mode-catalog-rules catalog)))
        (auto-mode-catalog-generation-set!
          catalog
          (+ (auto-mode-catalog-generation catalog) 1)))
      existing))

  (define (auto-mode-catalog-resolve catalog path fallback)
    (require-catalog 'auto-mode-catalog-resolve catalog)
    (unless (or (not path) (string? path))
      (assertion-violation
        'auto-mode-catalog-resolve
        "path must be a string or #f"
        path))
    (unless (symbol? fallback)
      (assertion-violation
        'auto-mode-catalog-resolve
        "fallback must be a symbol"
        fallback))
    (let ([rule
            (and
              path
              (find
                (lambda (candidate)
                  ((auto-mode-rule-matcher candidate) path))
                (auto-mode-catalog-rules catalog)))])
      (if rule (auto-mode-rule-major-mode rule) fallback)))

  (define (auto-mode-catalog-snapshot catalog)
    (require-catalog 'auto-mode-catalog-snapshot catalog)
    (%make-auto-mode-catalog-state
      (auto-mode-catalog-rules catalog)
      (auto-mode-catalog-generation catalog)))

  (define (auto-mode-catalog-restore! catalog snapshot)
    (require-catalog 'auto-mode-catalog-restore! catalog)
    (unless (auto-mode-catalog-state? snapshot)
      (assertion-violation
        'auto-mode-catalog-restore!
        "expected an auto mode catalog snapshot"
        snapshot))
    (auto-mode-catalog-rules-set!
      catalog
      (auto-mode-catalog-state-rules snapshot))
    (auto-mode-catalog-generation-set!
      catalog
      (auto-mode-catalog-state-generation snapshot))
    catalog))
