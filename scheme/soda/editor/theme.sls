(library (soda editor theme)
  (export make-face-spec
          face-spec?
          face-spec-foreground
          face-spec-background
          face-spec-attributes-add
          face-spec-attributes-remove
          make-theme
          theme?
          theme-name
          theme-appearance
          theme-generation
          theme-face-spec
          theme-resolve-faces
          make-theme-catalog
          theme-catalog?
          theme-catalog-register!
          theme-catalog-ref
          theme-catalog-names
          theme-catalog-themes)
  (import (rnrs))

  (define-record-type
    (face-spec %make-face-spec face-spec?)
    (fields foreground background attributes-add attributes-remove))

  (define-record-type
    (theme %make-theme theme?)
    (fields name appearance generation faces resolved-cache))

  (define-record-type
    (theme-catalog %make-theme-catalog theme-catalog?)
    (fields
      (immutable table theme-catalog-table)
      (mutable names theme-catalog-names theme-catalog-names-set!)))

  (define valid-attributes
    '(bold dim italic underline blink reverse hidden strike))

  (define (color? value)
    (or
      (memq value '(inherit default))
      (and (integer? value) (exact? value) (<= 0 value 255))
      (and
        (vector? value)
        (= (vector-length value) 3)
        (for-all
          (lambda (component)
            (and
              (integer? component)
              (exact? component)
              (<= 0 component 255)))
          (vector->list value)))))

  (define (attribute-list? value)
    (and
      (list? value)
      (for-all
        (lambda (attribute)
          (and
            (symbol? attribute)
            (memq attribute valid-attributes)))
        value)))

  (define (make-face-spec foreground background attributes-add attributes-remove)
    (unless
      (and
        (color? foreground)
        (color? background)
        (attribute-list? attributes-add)
        (attribute-list? attributes-remove))
      (assertion-violation
        'make-face-spec
        "invalid face specification"
        foreground
        background
        attributes-add
        attributes-remove))
    (%make-face-spec
      foreground
      background
      attributes-add
      attributes-remove))

  (define (make-theme name appearance generation entries)
    (unless
      (and
        (symbol? name)
        (memq appearance '(dark light))
        (integer? generation)
        (exact? generation)
        (not (negative? generation))
        (list? entries)
        (for-all
          (lambda (entry)
            (and
              (pair? entry)
              (symbol? (car entry))
              (face-spec? (cdr entry))))
          entries))
      (assertion-violation
        'make-theme
        "invalid theme"
        name
        appearance
        generation))
    (let ([faces (make-eq-hashtable)])
      (for-each
        (lambda (entry)
          (hashtable-set! faces (car entry) (cdr entry)))
        entries)
      (%make-theme
        name
        appearance
        generation
        faces
        (make-hashtable equal-hash equal?))))

  (define (parent-face-name face)
    (let ([name (symbol->string face)])
      (let loop ([index (- (string-length name) 1)])
        (cond
          [(negative? index) #f]
          [(char=? (string-ref name index) #\.)
           (and
             (positive? index)
             (string->symbol (substring name 0 index)))]
          [else (loop (- index 1))]))))

  (define empty-face-spec
    (make-face-spec 'inherit 'inherit '() '()))

  (define (theme-face-spec value face)
    (unless (theme? value)
      (assertion-violation
        'theme-face-spec
        "expected a theme"
        value))
    (unless (symbol? face)
      (assertion-violation
        'theme-face-spec
        "face must be a symbol"
        face))
    (let loop ([candidate face])
      (let ([spec
              (hashtable-ref
                (theme-faces value)
                candidate
                #f)])
        (cond
          [spec spec]
          [(parent-face-name candidate) =>
           (lambda (parent) (loop parent))]
          [(not (eq? candidate 'default))
           (loop 'default)]
          [else empty-face-spec]))))

  (define (adjoin value values)
    (if (memq value values)
        values
        (append values (list value))))

  (define (remove-attributes attributes removed)
    (filter
      (lambda (attribute)
        (not (memq attribute removed)))
      attributes))

  (define (merge-face-spec base overlay)
    (make-face-spec
      (if (eq? (face-spec-foreground overlay) 'inherit)
          (face-spec-foreground base)
          (face-spec-foreground overlay))
      (if (eq? (face-spec-background overlay) 'inherit)
          (face-spec-background base)
          (face-spec-background overlay))
      (fold-left
        (lambda (attributes attribute)
          (adjoin attribute attributes))
        (remove-attributes
          (face-spec-attributes-add base)
          (face-spec-attributes-remove overlay))
        (face-spec-attributes-add overlay))
      '()))

  (define (theme-resolve-faces value faces)
    (unless (theme? value)
      (assertion-violation
        'theme-resolve-faces
        "expected a theme"
        value))
    (unless (and (list? faces) (for-all symbol? faces))
      (assertion-violation
        'theme-resolve-faces
        "faces must be a list of symbols"
        faces))
    (or
      (hashtable-ref (theme-resolved-cache value) faces #f)
      (let ([resolved
              (fold-left
                (lambda (result face)
                  (merge-face-spec
                    result
                    (theme-face-spec value face)))
                empty-face-spec
                faces)])
        (hashtable-set!
          (theme-resolved-cache value)
          faces
          resolved)
        resolved)))

  (define make-theme-catalog
    (case-lambda
      [()
       (%make-theme-catalog (make-eq-hashtable) '())]
      [(themes)
       (unless (and (list? themes) (for-all theme? themes))
         (assertion-violation
           'make-theme-catalog
           "expected a list of themes"
           themes))
       (let ([catalog (make-theme-catalog)])
         (for-each
           (lambda (theme)
             (theme-catalog-register! catalog theme))
           themes)
         catalog)]))

  (define (theme-catalog-register! catalog value)
    (unless (theme-catalog? catalog)
      (assertion-violation
        'theme-catalog-register!
        "expected a theme catalog"
        catalog))
    (unless (theme? value)
      (assertion-violation
        'theme-catalog-register!
        "expected a theme"
        value))
    (let ([name (theme-name value)])
      (unless (hashtable-contains? (theme-catalog-table catalog) name)
        (theme-catalog-names-set!
          catalog
          (append (theme-catalog-names catalog) (list name))))
      (hashtable-set! (theme-catalog-table catalog) name value))
    value)

  (define (theme-catalog-ref catalog name)
    (unless (theme-catalog? catalog)
      (assertion-violation
        'theme-catalog-ref
        "expected a theme catalog"
        catalog))
    (unless (symbol? name)
      (assertion-violation
        'theme-catalog-ref
        "theme name must be a symbol"
        name))
    (hashtable-ref (theme-catalog-table catalog) name #f))

  (define (theme-catalog-themes catalog)
    (unless (theme-catalog? catalog)
      (assertion-violation
        'theme-catalog-themes
        "expected a theme catalog"
        catalog))
    (map
      (lambda (name)
        (theme-catalog-ref catalog name))
      (theme-catalog-names catalog))))
