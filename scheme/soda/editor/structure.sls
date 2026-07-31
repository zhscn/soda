(library (soda editor structure)
  (export make-structural-thing
          structural-thing?
          structural-thing-roles
          structural-thing-start
          structural-thing-end
          structural-thing-inner-start
          structural-thing-inner-end
          structural-thing-depth
          structural-thing-node-kind
          structural-thing-properties
          structural-thing-has-role?
          make-structure-index
          structure-index?
          structure-index-document-id
          structure-index-revision
          structure-index-things
          structure-index-things-in-range
          structure-index-thing-at
          structure-index-parent
          structure-index-next
          structure-index-previous
          structure-forward-target
          structure-backward-target
          structure-up-target
          structure-down-target
          make-structure-provider
          structure-provider?
          structure-provider-build)
  (import (rnrs)
          (soda document))

  (define-record-type
    (structural-thing %make-structural-thing structural-thing?)
    (fields
      roles
      start
      end
      inner-start
      inner-end
      depth
      node-kind
      properties))

  (define-record-type
    (structure-index %make-structure-index structure-index?)
    (fields document-id revision things))

  (define-record-type
    (structure-provider %make-structure-provider structure-provider?)
    (fields (immutable build structure-provider-builder)))

  (define (exact-non-negative-integer? value)
    (and
      (integer? value)
      (exact? value)
      (not (negative? value))))

  (define (symbol-alist? value)
    (and
      (list? value)
      (for-all
        (lambda (entry)
          (and (pair? entry) (symbol? (car entry))))
        value)))

  (define (make-structural-thing
            roles
            start
            end
            inner-start
            inner-end
            depth
            node-kind
            properties)
    (unless
      (and
        (pair? roles)
        (for-all symbol? roles)
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (<= start end)
        (exact-non-negative-integer? inner-start)
        (exact-non-negative-integer? inner-end)
        (<= start inner-start inner-end end)
        (exact-non-negative-integer? depth)
        (or (not node-kind) (symbol? node-kind) (string? node-kind))
        (symbol-alist? properties))
      (assertion-violation
        'make-structural-thing
        "invalid structural thing"
        roles
        start
        end
        inner-start
        inner-end
        depth
        node-kind
        properties))
    (%make-structural-thing
      roles
      start
      end
      inner-start
      inner-end
      depth
      node-kind
      properties))

  (define (structural-thing-has-role? thing role)
    (unless (structural-thing? thing)
      (assertion-violation
        'structural-thing-has-role?
        "expected a structural thing"
        thing))
    (unless (symbol? role)
      (assertion-violation
        'structural-thing-has-role?
        "role must be a symbol"
        role))
    (and (memq role (structural-thing-roles thing)) #t))

  (define (thing-before? left right)
    (or
      (< (structural-thing-start left)
         (structural-thing-start right))
      (and
        (= (structural-thing-start left)
           (structural-thing-start right))
        (> (structural-thing-end left)
           (structural-thing-end right)))
      (and
        (= (structural-thing-start left)
           (structural-thing-start right))
        (= (structural-thing-end left)
           (structural-thing-end right))
        (< (structural-thing-depth left)
           (structural-thing-depth right)))))

  (define (make-structure-index document-id revision things)
    (unless
      (and
        (exact-non-negative-integer? document-id)
        (exact-non-negative-integer? revision)
        (list? things)
        (for-all structural-thing? things))
      (assertion-violation
        'make-structure-index
        "invalid structure index"
        document-id
        revision
        things))
    (%make-structure-index
      document-id
      revision
      (list-sort thing-before? things)))

  (define (role-matches? thing role)
    (or
      (not role)
      (structural-thing-has-role? thing role)))

  (define (range-overlaps? thing start end)
    (and
      (< (structural-thing-start thing) end)
      (< start (structural-thing-end thing))))

  (define (structure-index-things-in-range index role start end)
    (unless (structure-index? index)
      (assertion-violation
        'structure-index-things-in-range
        "expected a structure index"
        index))
    (unless
      (and
        (or (not role) (symbol? role))
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (<= start end))
      (assertion-violation
        'structure-index-things-in-range
        "invalid structure query"
        role
        start
        end))
    (filter
      (lambda (thing)
        (and
          (role-matches? thing role)
          (range-overlaps? thing start end)))
      (structure-index-things index)))

  (define (thing-span thing)
    (- (structural-thing-end thing)
       (structural-thing-start thing)))

  (define (more-specific? left right)
    (or
      (not right)
      (< (thing-span left) (thing-span right))
      (and
        (= (thing-span left) (thing-span right))
        (> (structural-thing-depth left)
           (structural-thing-depth right)))))

  (define (structure-index-thing-at index role offset)
    (unless
      (and
        (structure-index? index)
        (or (not role) (symbol? role))
        (exact-non-negative-integer? offset))
      (assertion-violation
        'structure-index-thing-at
        "invalid structure point query"
        index
        role
        offset))
    (fold-left
      (lambda (best thing)
        (if
          (and
            (role-matches? thing role)
            (<= (structural-thing-start thing) offset)
            (< offset (structural-thing-end thing))
            (more-specific? thing best))
          thing
          best))
      #f
      (structure-index-things index)))

  (define (structure-index-parent index thing role)
    (unless
      (and
        (structure-index? index)
        (structural-thing? thing)
        (or (not role) (symbol? role)))
      (assertion-violation
        'structure-index-parent
        "invalid structure parent query"
        index
        thing
        role))
    (fold-left
      (lambda (best candidate)
        (if
          (and
            (not (eq? candidate thing))
            (role-matches? candidate role)
            (<= (structural-thing-start candidate)
                (structural-thing-start thing))
            (<= (structural-thing-end thing)
                (structural-thing-end candidate))
            (or
              (< (structural-thing-start candidate)
                 (structural-thing-start thing))
              (< (structural-thing-end thing)
                 (structural-thing-end candidate)))
            (more-specific? candidate best))
          candidate
          best))
      #f
      (structure-index-things index)))

  (define (structure-index-next index role offset)
    (fold-left
      (lambda (best thing)
        (if
          (and
            (role-matches? thing role)
            (>= (structural-thing-start thing) offset)
            (or
              (not best)
              (< (structural-thing-start thing)
                 (structural-thing-start best))
              (and
                (= (structural-thing-start thing)
                   (structural-thing-start best))
                (> (thing-span thing) (thing-span best)))))
          thing
          best))
      #f
      (structure-index-things index)))

  (define (structure-index-previous index role offset)
    (fold-left
      (lambda (best thing)
        (if
          (and
            (role-matches? thing role)
            (<= (structural-thing-end thing) offset)
            (or
              (not best)
              (> (structural-thing-end thing)
                 (structural-thing-end best))
              (and
                (= (structural-thing-end thing)
                   (structural-thing-end best))
                (> (thing-span thing) (thing-span best)))))
          thing
          best))
      #f
      (structure-index-things index)))

  (define (atomic-thing-at index role offset)
    (fold-left
      (lambda (best thing)
        (if
          (and
            (role-matches? thing role)
            (not (structural-thing-has-role? thing 'list))
            (< (structural-thing-start thing) offset)
            (< offset (structural-thing-end thing))
            (more-specific? thing best))
          thing
          best))
      #f
      (structure-index-things index)))

  (define (structure-forward-once index role offset)
    (let ([inside (atomic-thing-at index role offset)])
      (if inside
          (structural-thing-end inside)
          (let ([next (structure-index-next index role offset)])
            (and next (structural-thing-end next))))))

  (define (structure-backward-once index role offset)
    (let ([inside (atomic-thing-at index role offset)])
      (if inside
          (structural-thing-start inside)
          (let ([previous
                  (structure-index-previous index role offset)])
            (and previous (structural-thing-start previous))))))

  (define (structure-forward-target index role offset count)
    (unless
      (and
        (structure-index? index)
        (symbol? role)
        (exact-non-negative-integer? offset)
        (integer? count)
        (exact? count))
      (assertion-violation
        'structure-forward-target
        "invalid structural motion"
        index
        role
        offset
        count))
    (if (negative? count)
        (let loop ([remaining (- count)] [position offset])
          (if (zero? remaining)
              position
              (let ([next
                      (structure-backward-once
                        index role position)])
                (and next (loop (- remaining 1) next)))))
        (let loop ([remaining count] [position offset])
          (if (zero? remaining)
              position
              (let ([next
                      (structure-forward-once
                        index role position)])
                (and next (loop (- remaining 1) next)))))))

  (define (structure-backward-target index role offset count)
    (structure-forward-target index role offset (- count)))

  (define (enclosing-list index offset backward?)
    (fold-left
      (lambda (best thing)
        (if
          (and
            (structural-thing-has-role? thing 'list)
            (if backward?
                (and
                  (< (structural-thing-start thing) offset)
                  (<= offset (structural-thing-end thing)))
                (and
                  (<= (structural-thing-start thing) offset)
                  (< offset (structural-thing-end thing))))
            (more-specific? thing best))
          thing
          best))
      #f
      (structure-index-things index)))

  (define (structure-up-target index offset direction)
    (unless (memq direction '(backward forward))
      (assertion-violation
        'structure-up-target
        "direction must be backward or forward"
        direction))
    (let ([list
            (enclosing-list
              index
              offset
              (eq? direction 'backward))])
      (and
        list
        (if (eq? direction 'backward)
            (structural-thing-start list)
            (structural-thing-end list)))))

  (define (structure-down-target index offset direction)
    (unless (memq direction '(backward forward))
      (assertion-violation
        'structure-down-target
        "direction must be backward or forward"
        direction))
    (let ([list
            (if (eq? direction 'forward)
                (structure-index-next index 'list offset)
                (structure-index-previous index 'list offset))])
      (and
        list
        (if (eq? direction 'forward)
            (structural-thing-inner-start list)
            (structural-thing-inner-end list)))))

  (define (make-structure-provider build)
    (unless (procedure? build)
      (assertion-violation
        'make-structure-provider
        "build must be a procedure"
        build))
    (%make-structure-provider build))

  (define (structure-provider-build provider syntax-session snapshot)
    (unless (structure-provider? provider)
      (assertion-violation
        'structure-provider-build
        "expected a structure provider"
        provider))
    (unless (snapshot? snapshot)
      (assertion-violation
        'structure-provider-build
        "expected a document snapshot"
        snapshot))
    (let ([index
            ((structure-provider-builder provider)
             syntax-session
             snapshot)])
      (unless
        (and
          (structure-index? index)
          (= (structure-index-document-id index)
             (snapshot-document-id snapshot))
          (= (structure-index-revision index)
             (snapshot-revision snapshot)))
        (assertion-violation
          'structure-provider-build
          "provider returned an inconsistent structure index"
          index))
      index)))
