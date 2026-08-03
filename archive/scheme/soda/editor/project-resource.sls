(library (soda editor project-resource)
  (export make-project-resource-policy
          project-resource-policy?
          project-resource-policy-include-hidden?
          project-resource-policy-ignored-directory-names
          project-resource-policy-include-entry?
          default-project-resource-policy
          make-project-resource-request
          project-resource-request?
          project-resource-request-project
          project-resource-request-generation
          project-resource-request-policy
          project-resource-request-continuation
          make-project-resource-snapshot
          project-resource-snapshot?
          project-resource-snapshot-project-id
          project-resource-snapshot-generation
          project-resource-snapshot-resources
          project-resource-snapshot-directories
          make-project-resource-result
          project-resource-result?
          project-resource-result-snapshot
          project-resource-result-continuation)
  (import (rnrs)
          (soda editor project)
          (soda vfs))

  (define-record-type
    (project-resource-policy
      %make-project-resource-policy
      project-resource-policy?)
    (fields include-hidden? ignored-directory-names include-entry?))

  (define-record-type
    (project-resource-request
      %make-project-resource-request
      project-resource-request?)
    (fields project generation policy continuation))

  (define-record-type
    (project-resource-snapshot
      %make-project-resource-snapshot
      project-resource-snapshot?)
    (fields project-id generation resources directories))

  (define-record-type project-resource-result
    (fields snapshot continuation))

  (define (valid-name-list? value)
    (and (list? value)
         (for-all
           (lambda (name)
             (and (string? name) (positive? (string-length name))))
           value)))

  (define (make-project-resource-policy
            include-hidden?
            ignored-directory-names
            include-entry?)
    (unless (boolean? include-hidden?)
      (assertion-violation
        'make-project-resource-policy
        "include-hidden flag must be a boolean"
        include-hidden?))
    (unless (valid-name-list? ignored-directory-names)
      (assertion-violation
        'make-project-resource-policy
        "ignored directory names must be a list of non-empty strings"
        ignored-directory-names))
    (unless (procedure? include-entry?)
      (assertion-violation
        'make-project-resource-policy
        "include-entry predicate must be a procedure"
        include-entry?))
    (%make-project-resource-policy
      include-hidden?
      ignored-directory-names
      include-entry?))

  (define default-project-resource-policy
    (make-project-resource-policy
      #f
      '(".git" ".hg" ".svn" ".cache"
        "build" "node_modules" "target" "vendor")
      (lambda (path entry) #t)))

  (define make-project-resource-request
    (case-lambda
      [(project generation policy)
       (make-project-resource-request project generation policy #f)]
      [(project generation policy continuation)
       (unless (project? project)
         (assertion-violation
           'make-project-resource-request
           "expected a project"
           project))
       (unless
         (and (integer? generation) (exact? generation)
              (not (negative? generation)))
         (assertion-violation
           'make-project-resource-request
           "generation must be a non-negative exact integer"
           generation))
       (unless (project-resource-policy? policy)
         (assertion-violation
           'make-project-resource-request
           "expected a project resource policy"
           policy))
       (%make-project-resource-request
         project generation policy continuation)]))

  (define (make-project-resource-snapshot
            project-id generation resources directories)
    (unless (or (symbol? project-id) (string? project-id))
      (assertion-violation
        'make-project-resource-snapshot
        "project id must be a symbol or string"
        project-id))
    (unless
      (and (integer? generation) (exact? generation)
           (not (negative? generation)))
      (assertion-violation
        'make-project-resource-snapshot
        "generation must be a non-negative exact integer"
        generation))
    (unless
      (and (list? resources) (for-all string? resources)
           (list? directories) (for-all string? directories))
      (assertion-violation
        'make-project-resource-snapshot
        "resources and directories must be string lists"
        resources
        directories))
    (%make-project-resource-snapshot
      project-id generation resources directories))
)
