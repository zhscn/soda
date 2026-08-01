(library (soda tui application)
  (export make-tui-dimension
          tui-dimension?
          tui-dimension-kind
          tui-dimension-amount
          tui-dimension-minimum
          tui-dimension-maximum
          tui-fixed
          tui-content
          tui-flex
          tui-percent
          make-tui-layout
          tui-layout?
          tui-layout-width
          tui-layout-height
          make-tui-focus
          tui-focus?
          tui-focus-focusable?
          tui-focus-group
          tui-focus-order
          tui-focus-enabled?
          make-tui-accessibility
          tui-accessibility?
          tui-accessibility-role
          tui-accessibility-label
          tui-accessibility-value
          tui-accessibility-description
          tui-accessibility-selection
          tui-accessibility-copy-value
          tui-accessibility-commands
          tui-accessibility-keymap
          make-tui-node
          tui-node?
          tui-node-key
          tui-node-kind
          tui-node-layout
          tui-node-faces
          tui-node-content
          tui-node-children
          tui-node-focus
          tui-node-semantic-source
          tui-node-accessibility
          tui-node-with-layout
          tui-node-with-focus
          tui-node-with-accessibility
          tui-node-find
          tui-text
          tui-styled-text
          tui-row
          tui-column
          tui-stack
          tui-padding
          tui-border
          tui-scroll
          tui-list
          tui-table
          tui-spacer
          tui-custom
          make-tui-size
          tui-size?
          tui-size-rows
          tui-size-columns
          tui-measure
          make-tui-arranged-node
          tui-arranged-node?
          tui-arranged-node-node
          tui-arranged-node-rect
          tui-arranged-node-children
          tui-arranged-node-find
          tui-arrange
          make-tui-focus-entry
          tui-focus-entry?
          tui-focus-entry-node-key
          tui-focus-entry-rect
          tui-focus-entry-order
          tui-focus-entry-enabled?
          tui-focus-entry-group
          tui-focus-entry-path
          tui-focus-ring-repair
          make-tui-cursor
          tui-cursor?
          tui-cursor-node-key
          tui-cursor-local-row
          tui-cursor-local-column
          tui-cursor-shape
          tui-cursor-visible?
          make-tui-surface
          tui-surface?
          tui-surface-rows
          tui-surface-columns
          tui-surface-frame
          tui-surface-component-tree
          tui-surface-arranged-tree
          tui-surface-focus-ring
          tui-surface-cursor
          tui-render-surface)
  (import (rnrs)
          (soda editor display)
          (soda editor theme)
          (soda tui component)
          (soda tui frame))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define-record-type
    (tui-dimension %make-tui-dimension tui-dimension?)
    (fields kind amount minimum maximum))

  (define (make-tui-dimension kind amount minimum maximum)
    (unless (memq kind '(fixed content flex percentage))
      (assertion-violation
        'make-tui-dimension "unknown dimension kind" kind))
    (unless
      (case kind
        [(content) (not amount)]
        [(flex) (and (integer? amount) (exact? amount) (positive? amount))]
        [(percentage)
         (and (integer? amount) (exact? amount) (<= 0 amount 100))]
        [else (exact-non-negative-integer? amount)])
      (assertion-violation
        'make-tui-dimension "invalid dimension amount" kind amount))
    (unless (and
              (or (not minimum) (exact-non-negative-integer? minimum))
              (or (not maximum) (exact-non-negative-integer? maximum))
              (or (not minimum) (not maximum) (<= minimum maximum)))
      (assertion-violation
        'make-tui-dimension "invalid dimension bounds" minimum maximum))
    (%make-tui-dimension kind amount minimum maximum))

  (define tui-fixed
    (case-lambda
      [(amount) (make-tui-dimension 'fixed amount #f #f)]
      [(amount minimum maximum)
       (make-tui-dimension 'fixed amount minimum maximum)]))

  (define tui-content
    (case-lambda
      [() (make-tui-dimension 'content #f #f #f)]
      [(minimum maximum)
       (make-tui-dimension 'content #f minimum maximum)]))

  (define tui-flex
    (case-lambda
      [() (make-tui-dimension 'flex 1 #f #f)]
      [(weight) (make-tui-dimension 'flex weight #f #f)]
      [(weight minimum maximum)
       (make-tui-dimension 'flex weight minimum maximum)]))

  (define tui-percent
    (case-lambda
      [(percentage)
       (make-tui-dimension 'percentage percentage #f #f)]
      [(percentage minimum maximum)
       (make-tui-dimension
         'percentage percentage minimum maximum)]))

  (define-record-type
    (tui-layout %make-tui-layout tui-layout?)
    (fields width height))

  (define (make-tui-layout width height)
    (unless (and (tui-dimension? width) (tui-dimension? height))
      (assertion-violation
        'make-tui-layout "expected width and height dimensions"
        width height))
    (%make-tui-layout width height))

  (define-record-type
    (tui-focus %make-tui-focus tui-focus?)
    (fields focusable? group order enabled?))

  (define (make-tui-focus focusable? group order enabled?)
    (unless (and (boolean? focusable?)
                 (or (not order) (exact-non-negative-integer? order))
                 (boolean? enabled?))
      (assertion-violation
        'make-tui-focus "invalid focus declaration"
        focusable? group order enabled?))
    (%make-tui-focus focusable? group order enabled?))

  (define-record-type
    (tui-accessibility %make-tui-accessibility tui-accessibility?)
    (fields role label value description selection copy-value commands keymap))

  (define make-tui-accessibility
    (case-lambda
      [(role label value description commands keymap)
       (make-tui-accessibility
         role label value description #f #f commands keymap)]
      [(role label value description selection copy-value commands keymap)
       (unless (or (not role) (symbol? role))
         (assertion-violation
           'make-tui-accessibility "role must be a symbol or #f" role))
       (for-each
         (lambda (entry)
           (unless (or (not (cdr entry)) (string? (cdr entry)))
             (assertion-violation
               'make-tui-accessibility
               "text metadata must be a string or #f"
               (car entry)
               (cdr entry))))
         (list
           (cons 'label label)
           (cons 'value value)
           (cons 'description description)
           (cons 'selection selection)))
       (unless (or (not copy-value)
                   (string? copy-value)
                   (bytevector? copy-value))
         (assertion-violation
           'make-tui-accessibility
           "copy value must be a string, bytevector, or #f"
           copy-value))
       (unless (and (list? commands) (for-all symbol? commands))
         (assertion-violation
           'make-tui-accessibility
           "commands must contain symbols"
           commands))
       (%make-tui-accessibility
         role label value description selection copy-value commands keymap)]))

  (define-record-type
    (tui-node %make-tui-node tui-node?)
    (fields key kind layout faces content children focus
            semantic-source accessibility))

  (define valid-kinds
    '(text styled-text row column stack padding border scroll
      list table spacer custom))

  (define (unique-keys? children)
    (let loop ([remaining children])
      (or
        (null? remaining)
        (and
          (not
            (exists
              (lambda (child)
                (equal? (tui-node-key child)
                        (tui-node-key (car remaining))))
              (cdr remaining)))
          (loop (cdr remaining))))))

  (define (make-tui-node
            key kind layout faces content children focus
            semantic-source accessibility)
    (when (not key)
      (assertion-violation 'make-tui-node "node key must not be #f" key))
    (unless (memq kind valid-kinds)
      (assertion-violation 'make-tui-node "unknown node kind" kind))
    (unless (tui-layout? layout)
      (assertion-violation 'make-tui-node "expected a TuiLayout" layout))
    (unless (and (list? faces) (for-all symbol? faces))
      (assertion-violation
        'make-tui-node "faces must contain symbols" faces))
    (unless (and (list? children)
                 (for-all tui-node? children)
                 (unique-keys? children))
      (assertion-violation
        'make-tui-node "sibling node keys must be unique" children))
    (unless (or (not focus) (tui-focus? focus))
      (assertion-violation 'make-tui-node "invalid focus metadata" focus))
    (unless (or (not accessibility) (tui-accessibility? accessibility))
      (assertion-violation
        'make-tui-node "invalid accessibility metadata" accessibility))
    (%make-tui-node
      key kind layout faces content children focus
      semantic-source accessibility))

  (define content-layout
    (make-tui-layout (tui-content) (tui-content)))

  (define (rebuild-node node layout focus)
    (make-tui-node
      (tui-node-key node)
      (tui-node-kind node)
      layout
      (tui-node-faces node)
      (tui-node-content node)
      (tui-node-children node)
      focus
      (tui-node-semantic-source node)
      (tui-node-accessibility node)))

  (define (tui-node-with-layout node layout)
    (unless (tui-node? node)
      (assertion-violation
        'tui-node-with-layout "expected a TuiNode" node))
    (rebuild-node node layout (tui-node-focus node)))

  (define (tui-node-with-focus node focus)
    (unless (tui-node? node)
      (assertion-violation
        'tui-node-with-focus "expected a TuiNode" node))
    (rebuild-node node (tui-node-layout node) focus))

  (define (tui-node-with-accessibility node accessibility)
    (unless (tui-node? node)
      (assertion-violation
        'tui-node-with-accessibility "expected a TuiNode" node))
    (unless (or (not accessibility) (tui-accessibility? accessibility))
      (assertion-violation
        'tui-node-with-accessibility
        "expected accessibility metadata or #f"
        accessibility))
    (make-tui-node
      (tui-node-key node)
      (tui-node-kind node)
      (tui-node-layout node)
      (tui-node-faces node)
      (tui-node-content node)
      (tui-node-children node)
      (tui-node-focus node)
      (tui-node-semantic-source node)
      accessibility))

  (define (tui-node-find node key)
    (unless (tui-node? node)
      (assertion-violation 'tui-node-find "expected a TuiNode" node))
    (if (equal? (tui-node-key node) key)
        node
        (let loop ([children (tui-node-children node)])
          (and
            (pair? children)
            (or (tui-node-find (car children) key)
                (loop (cdr children)))))))

  (define tui-text
    (case-lambda
      [(key text) (tui-text key text '(application))]
      [(key text faces)
       (unless (string? text)
         (assertion-violation 'tui-text "text must be a string" text))
       (make-tui-node
         key 'text content-layout faces text '() #f #f #f)]))

  (define (valid-span? span)
    (and (list? span)
         (= (length span) 2)
         (string? (car span))
         (list? (cadr span))
         (for-all symbol? (cadr span))))

  (define (tui-styled-text key spans)
    (unless (and (list? spans) (for-all valid-span? spans))
      (assertion-violation
        'tui-styled-text "spans must contain text and face lists" spans))
    (make-tui-node
      key 'styled-text content-layout '(application)
      spans '() #f #f #f))

  (define (container key kind children)
    (make-tui-node
      key kind content-layout '(application)
      #f children #f #f #f))

  (define (tui-row key children) (container key 'row children))
  (define (tui-column key children) (container key 'column children))
  (define (tui-stack key children) (container key 'stack children))

  (define (tui-padding key top right bottom left child)
    (unless (and (exact-non-negative-integer? top)
                 (exact-non-negative-integer? right)
                 (exact-non-negative-integer? bottom)
                 (exact-non-negative-integer? left)
                 (tui-node? child))
      (assertion-violation 'tui-padding "invalid padding" key))
    (make-tui-node
      key 'padding content-layout '(application)
      (vector top right bottom left) (list child) #f #f #f))

  (define tui-border
    (case-lambda
      [(key child) (tui-border key child '(application.border))]
      [(key child faces)
       (make-tui-node
         key 'border content-layout faces
         #f (list child) #f #f #f)]))

  (define (tui-scroll key child viewport)
    (unless (and (tui-node? child)
                 (pair? viewport)
                 (exact-non-negative-integer? (car viewport))
                 (exact-non-negative-integer? (cdr viewport)))
      (assertion-violation
        'tui-scroll
        "viewport must be a non-negative row/column pair"
        viewport))
    (make-tui-node
      key 'scroll content-layout '(application)
      viewport (list child) #f #f #f))

  (define (row-node parent-key row index selected?)
    (let ([key (cons parent-key index)])
      (cond
        [(tui-node? row) row]
        [(string? row)
         (tui-text
           key row
           (if selected?
               '(application application.selection)
               '(application)))]
        [else
         (assertion-violation
           'tui-list "rows must be strings or TuiNodes" row)])))

  (define (tui-list key rows selection)
    (unless (and (list? rows)
                 (or (not selection)
                     (and (integer? selection)
                          (exact? selection)
                          (<= 0 selection)
                          (< selection (length rows)))))
      (assertion-violation 'tui-list "invalid rows or selection" rows selection))
    (make-tui-node
      key 'list content-layout '(application)
      selection
      (let loop ([rows rows] [index 0])
        (if (null? rows)
            '()
            (cons
              (row-node key (car rows) index (eqv? selection index))
              (loop (cdr rows) (+ index 1)))))
      #f #f #f))

  (define (table-row key cells row-index)
    (tui-row
      (cons key row-index)
      (let loop ([cells cells] [column-index 0])
        (if (null? cells)
            '()
            (cons
              (tui-node-with-layout
                (tui-text
                  (list key row-index column-index)
                  (if (string? (car cells))
                      (car cells)
                      (call-with-values
                        open-string-output-port
                        (lambda (port extract)
                          (write (car cells) port)
                          (extract)))))
                (make-tui-layout (tui-flex 1) (tui-content)))
              (loop (cdr cells) (+ column-index 1)))))))

  (define (tui-table key rows)
    (unless (and (list? rows) (for-all list? rows))
      (assertion-violation 'tui-table "rows must contain cell lists" rows))
    (make-tui-node
      key 'table content-layout '(application)
      #f
      (let loop ([rows rows] [index 0])
        (if (null? rows)
            '()
            (cons
              (table-row key (car rows) index)
              (loop (cdr rows) (+ index 1)))))
      #f #f #f))

  (define tui-spacer
    (case-lambda
      [(key)
       (tui-node-with-layout
         (make-tui-node
           key 'spacer content-layout '(application)
           #f '() #f #f #f)
         (make-tui-layout (tui-flex 1) (tui-flex 1)))]
      [(key layout)
       (tui-node-with-layout (tui-spacer key) layout)]))

  (define (tui-custom key measure paint layout)
    (unless (and (procedure? measure) (procedure? paint))
      (assertion-violation
        'tui-custom "measure and paint must be procedures" key))
    (make-tui-node
      key 'custom layout '(application)
      (cons measure paint) '() #f #f #f))

  (define-record-type
    (tui-size %make-tui-size tui-size?)
    (fields rows columns))

  (define (make-tui-size rows columns)
    (unless (and (exact-non-negative-integer? rows)
                 (exact-non-negative-integer? columns))
      (assertion-violation 'make-tui-size "invalid size" rows columns))
    (%make-tui-size rows columns))

  (define (string-lines value)
    (let ([length (string-length value)])
      (let loop ([start 0] [index 0] [result '()])
        (cond
          [(= index length)
           (reverse (cons (substring value start index) result))]
          [(char=? (string-ref value index) #\newline)
           (loop (+ index 1) (+ index 1)
                 (cons (substring value start index) result))]
          [else (loop start (+ index 1) result)]))))

  (define (text-size text)
    (let ([lines (string-lines text)])
      (make-tui-size
        (length lines)
        (fold-left
          (lambda (width line)
            (max width (string-cell-width line 8)))
          0
          lines))))

  (define (styled-text-string spans)
    (apply string-append (map car spans)))

  (define (padding-size node child-size)
    (let ([padding (tui-node-content node)])
      (make-tui-size
        (+ (tui-size-rows child-size)
           (vector-ref padding 0)
           (vector-ref padding 2))
        (+ (tui-size-columns child-size)
           (vector-ref padding 1)
           (vector-ref padding 3)))))

  (define (tui-measure node max-rows max-columns)
    (unless (and (tui-node? node)
                 (exact-non-negative-integer? max-rows)
                 (exact-non-negative-integer? max-columns))
      (assertion-violation
        'tui-measure "invalid node or constraints" node max-rows max-columns))
    (let* ([children (tui-node-children node)]
           [sizes
             (map
               (lambda (child) (tui-measure child max-rows max-columns))
               children)]
           [raw
             (case (tui-node-kind node)
               [(text) (text-size (tui-node-content node))]
               [(styled-text)
                (text-size (styled-text-string (tui-node-content node)))]
               [(row)
                (make-tui-size
                  (fold-left
                    (lambda (rows size) (max rows (tui-size-rows size)))
                    0 sizes)
                  (fold-left
                    (lambda (columns size) (+ columns (tui-size-columns size)))
                    0 sizes))]
               [(column list table)
                (make-tui-size
                  (fold-left
                    (lambda (rows size) (+ rows (tui-size-rows size)))
                    0 sizes)
                  (fold-left
                    (lambda (columns size)
                      (max columns (tui-size-columns size)))
                    0 sizes))]
               [(stack scroll)
                (make-tui-size
                  (fold-left
                    (lambda (rows size) (max rows (tui-size-rows size)))
                    0 sizes)
                  (fold-left
                    (lambda (columns size)
                      (max columns (tui-size-columns size)))
                    0 sizes))]
               [(padding) (padding-size node (car sizes))]
               [(border)
                (make-tui-size
                  (+ 2 (tui-size-rows (car sizes)))
                  (+ 2 (tui-size-columns (car sizes))))]
               [(custom)
                ((car (tui-node-content node)) max-rows max-columns)]
               [else (make-tui-size 0 0)])])
      (make-tui-size
        (min max-rows (tui-size-rows raw))
        (min max-columns (tui-size-columns raw)))))

  (define-record-type tui-arranged-node
    (fields node rect children))

  (define (bound-amount amount dimension)
    (min
      (or (tui-dimension-maximum dimension) amount)
      (max (or (tui-dimension-minimum dimension) 0) amount)))

  (define (dimension-amount dimension total desired)
    (bound-amount
      (case (tui-dimension-kind dimension)
        [(fixed) (tui-dimension-amount dimension)]
        [(percentage)
         (div (* total (tui-dimension-amount dimension)) 100)]
        [(content) desired]
        [(flex) 0])
      dimension))

  (define (axis-dimension node orientation)
    (if (eq? orientation 'horizontal)
        (tui-layout-width (tui-node-layout node))
        (tui-layout-height (tui-node-layout node))))

  (define (axis-desired size orientation)
    (if (eq? orientation 'horizontal)
        (tui-size-columns size)
        (tui-size-rows size)))

  (define (axis-allocations children sizes total orientation)
    (let* ([dimensions
             (map (lambda (child) (axis-dimension child orientation)) children)]
           [base
             (map
               (lambda (dimension size)
                 (dimension-amount
                   dimension total (axis-desired size orientation)))
               dimensions sizes)]
           [used (fold-left + 0 base)]
           [remaining (max 0 (- total used))]
           [weight
             (fold-left
               (lambda (sum dimension)
                 (if (eq? (tui-dimension-kind dimension) 'flex)
                     (+ sum (tui-dimension-amount dimension))
                     sum))
               0 dimensions)])
      (if (zero? weight)
          base
          (let loop ([dimensions dimensions]
                     [base base]
                     [remaining-weight weight]
                     [remaining-cells remaining])
            (if (null? dimensions)
                '()
                (let* ([dimension (car dimensions)]
                       [flex?
                         (eq? (tui-dimension-kind dimension) 'flex)]
                       [amount
                         (if flex?
                             (bound-amount
                               (if (= remaining-weight
                                      (tui-dimension-amount dimension))
                                   remaining-cells
                                   (div
                                     (* remaining-cells
                                        (tui-dimension-amount dimension))
                                     remaining-weight))
                               dimension)
                             (car base))])
                  (cons
                    amount
                    (loop
                      (cdr dimensions)
                      (cdr base)
                      (if flex?
                          (- remaining-weight
                             (tui-dimension-amount dimension))
                          remaining-weight)
                      (if flex?
                          (max 0 (- remaining-cells amount))
                          remaining-cells)))))))))

  (define (shrink-rect rect top right bottom left)
    (make-rect
      (+ (rect-row rect) (min top (rect-rows rect)))
      (+ (rect-column rect) (min left (rect-columns rect)))
      (max 0 (- (rect-rows rect) top bottom))
      (max 0 (- (rect-columns rect) left right))))

  (define (arrange-linear node rect orientation)
    (let* ([children (tui-node-children node)]
           [sizes
             (map
               (lambda (child)
                 (tui-measure child (rect-rows rect) (rect-columns rect)))
               children)]
           [total
             (if (eq? orientation 'horizontal)
                 (rect-columns rect)
                 (rect-rows rect))]
           [amounts (axis-allocations children sizes total orientation)])
      (let loop ([children children] [amounts amounts] [offset 0])
        (if (null? children)
            '()
            (let* ([amount (min (car amounts) (max 0 (- total offset)))]
                   [child-rect
                     (if (eq? orientation 'horizontal)
                         (make-rect
                           (rect-row rect)
                           (+ (rect-column rect) offset)
                           (rect-rows rect)
                           amount)
                         (make-rect
                           (+ (rect-row rect) offset)
                           (rect-column rect)
                           amount
                           (rect-columns rect)))])
              (cons
                (tui-arrange (car children) child-rect)
                (loop (cdr children) (cdr amounts) (+ offset amount))))))))

  (define (tui-arrange node rect)
    (unless (and (tui-node? node) (rect? rect))
      (assertion-violation 'tui-arrange "expected node and rectangle" node rect))
    (make-tui-arranged-node
      node
      rect
      (case (tui-node-kind node)
        [(row) (arrange-linear node rect 'horizontal)]
        [(column list table) (arrange-linear node rect 'vertical)]
        [(stack)
         (map (lambda (child) (tui-arrange child rect))
              (tui-node-children node))]
        [(scroll)
         (let* ([viewport (tui-node-content node)]
                [child (car (tui-node-children node))]
                [desired (tui-measure child 1000000 1000000)]
                [rows (max (rect-rows rect) (tui-size-rows desired))]
                [columns
                  (max (rect-columns rect) (tui-size-columns desired))])
           (list
             (tui-arrange
               child
               (make-rect
                 (- (rect-row rect) (car viewport))
                 (- (rect-column rect) (cdr viewport))
                 rows
                 columns))))]
        [(padding)
         (let ([padding (tui-node-content node)])
           (list
             (tui-arrange
               (car (tui-node-children node))
               (shrink-rect
                 rect
                 (vector-ref padding 0)
                 (vector-ref padding 1)
                 (vector-ref padding 2)
                 (vector-ref padding 3)))))]
        [(border)
         (list
           (tui-arrange
             (car (tui-node-children node))
             (shrink-rect rect 1 1 1 1)))]
        [else '()])))

  (define (tui-arranged-node-find arranged key)
    (unless (tui-arranged-node? arranged)
      (assertion-violation
        'tui-arranged-node-find "expected an arranged node" arranged))
    (if (equal? key (tui-node-key (tui-arranged-node-node arranged)))
        arranged
        (let loop ([children (tui-arranged-node-children arranged)])
          (and
            (pair? children)
            (or
              (tui-arranged-node-find (car children) key)
              (loop (cdr children)))))))

  (define-record-type tui-focus-entry
    (fields node-key rect order enabled? group path))

  (define (focus-entry-for-key entries key)
    (and key
         (find
           (lambda (entry)
             (equal? key (tui-focus-entry-node-key entry)))
           entries)))

  (define (common-prefix-length left right)
    (let loop ([left left] [right right] [length 0])
      (if (and (pair? left) (pair? right)
               (equal? (car left) (car right)))
          (loop (cdr left) (cdr right) (+ length 1))
          length)))

  (define (parent-path path)
    (if (null? path) '() (reverse (cdr (reverse path)))))

  (define (same-group-successor old-entry enabled)
    (let* ([group (tui-focus-entry-group old-entry)]
           [members
             (filter
               (lambda (entry)
                 (equal? group (tui-focus-entry-group entry)))
               enabled)]
           [later
             (find
               (lambda (entry)
                 (> (tui-focus-entry-order entry)
                    (tui-focus-entry-order old-entry)))
               members)])
      (or later (and (pair? members) (car members)))))

  (define (parent-scope-successor old-entry enabled)
    (let ([old-parent (parent-path (tui-focus-entry-path old-entry))])
      (let loop ([remaining enabled] [best #f] [best-score 0])
        (if (null? remaining)
            best
            (let* ([entry (car remaining)]
                   [score
                     (common-prefix-length
                       old-parent
                       (parent-path (tui-focus-entry-path entry)))])
              (if (> score best-score)
                  (loop (cdr remaining) entry score)
                  (loop (cdr remaining) best best-score)))))))

  (define (tui-focus-ring-repair current old-ring new-ring)
    (unless (and (list? old-ring) (list? new-ring)
                 (for-all tui-focus-entry? old-ring)
                 (for-all tui-focus-entry? new-ring))
      (assertion-violation
        'tui-focus-ring-repair "expected focus rings" old-ring new-ring))
    (let* ([enabled (filter tui-focus-entry-enabled? new-ring)]
           [current-entry (focus-entry-for-key enabled current)])
      (cond
        [current-entry current]
        [(not current)
         (and (pair? enabled)
              (tui-focus-entry-node-key (car enabled)))]
        [(focus-entry-for-key old-ring current)
         =>
         (lambda (old-entry)
           (let ([replacement
                   (or (same-group-successor old-entry enabled)
                       (parent-scope-successor old-entry enabled))])
             (and replacement
                  (tui-focus-entry-node-key replacement))))]
        [else
         (and (pair? enabled)
              (tui-focus-entry-node-key (car enabled)))])))

  (define-record-type
    (tui-cursor %make-tui-cursor tui-cursor?)
    (fields node-key local-row local-column shape visible?))

  (define (make-tui-cursor node-key local-row local-column shape visible?)
    (unless node-key
      (assertion-violation
        'make-tui-cursor "node key must not be #f" node-key))
    (unless (and (exact-non-negative-integer? local-row)
                 (exact-non-negative-integer? local-column))
      (assertion-violation
        'make-tui-cursor
        "local cursor coordinates must be non-negative exact integers"
        local-row
        local-column))
    (unless (memq shape
                  '(block underline bar
                    blinking-block blinking-underline blinking-bar))
      (assertion-violation
        'make-tui-cursor "unknown cursor shape" shape))
    (unless (boolean? visible?)
      (assertion-violation
        'make-tui-cursor "cursor visibility must be boolean" visible?))
    (%make-tui-cursor node-key local-row local-column shape visible?))

  (define-record-type tui-surface
    (fields rows columns frame component-tree arranged-tree focus-ring cursor))

  (define (datum->string value)
    (call-with-values
      open-string-output-port
      (lambda (port extract)
        (write value port)
        (extract))))

  (define (application-component-id session-id path)
    (string->symbol
      (string-append
        "application."
        (number->string session-id)
        "."
        (datum->string path))))

  (define (arranged->component-tree arranged session-id path)
    (let* ([node (tui-arranged-node-node arranged)]
           [node-path (append path (list (tui-node-key node)))])
      (make-component-node
        (application-component-id session-id node-path)
        (tui-arranged-node-rect arranged)
        #f
        (map
          (lambda (child)
            (arranged->component-tree child session-id node-path))
          (tui-arranged-node-children arranged)))))

  (define (resolve-faces theme faces)
    (let ([spec (theme-resolve-faces theme faces)])
      (make-style
        (if (eq? (face-spec-foreground spec) 'inherit)
            'default
            (face-spec-foreground spec))
        (if (eq? (face-spec-background spec) 'inherit)
            'default
            (face-spec-background spec))
        (face-spec-attributes-add spec))))

  (define (inside-frame? frame row column)
    (and (<= 0 row) (< row (frame-rows frame))
         (<= 0 column) (< column (frame-columns frame))))

  (define (intersect-rect left right)
    (let* ([row (max (rect-row left) (rect-row right))]
           [column (max (rect-column left) (rect-column right))]
           [end-row
             (min (+ (rect-row left) (rect-rows left))
                  (+ (rect-row right) (rect-rows right)))]
           [end-column
             (min (+ (rect-column left) (rect-columns left))
                  (+ (rect-column right) (rect-columns right)))])
      (make-rect
        row column
        (max 0 (- end-row row))
        (max 0 (- end-column column)))))

  (define (inside-clip? clip row column width)
    (and (<= (rect-row clip) row)
         (< row (+ (rect-row clip) (rect-rows clip)))
         (<= (rect-column clip) column)
         (<= (+ column width)
             (+ (rect-column clip) (rect-columns clip)))))

  (define (put-character!
            frame clip row column character faces theme session-id key)
    (let ([width (character-cell-width character)])
      (cond
        [(zero? width)
         (when (and (> column 0)
                    (inside-frame? frame row (- column 1))
                    (inside-clip? clip row (- column 1) 1))
           (frame-append-cell-text! frame row (- column 1) (string character)))
         column]
        [(and (inside-frame? frame row column)
              (inside-clip? clip row column width)
              (<= (+ column width) (frame-columns frame)))
         (frame-put-cell!
           frame row column
           (make-cell
             (string character)
             width
             faces
             (resolve-faces theme faces)
             #f
             (list (make-cell-source 'application session-id key))))
         (+ column width)]
        [else column])))

  (define (paint-string! frame rect clip text faces theme session-id key)
    (let ([row (rect-row rect)]
          [column (rect-column rect)]
          [end-row (+ (rect-row rect) (rect-rows rect))]
          [end-column (+ (rect-column rect) (rect-columns rect))])
      (for-each
        (lambda (character)
          (cond
            [(char=? character #\newline)
             (set! row (+ row 1))
             (set! column (rect-column rect))]
            [(char=? character #\tab)
             (let ([next (+ column (- 8 (mod column 8)))])
               (set! column (min end-column next)))]
            [(and (< row end-row) (< column end-column))
             (set! column
               (put-character!
                 frame clip row column character faces theme session-id key))]))
        (string->list text))))

  (define (paint-border! frame rect clip faces theme session-id key)
    (when (and (positive? (rect-rows rect))
               (positive? (rect-columns rect)))
      (let ([top (rect-row rect)]
            [left (rect-column rect)]
            [bottom (- (+ (rect-row rect) (rect-rows rect)) 1)]
            [right (- (+ (rect-column rect) (rect-columns rect)) 1)])
        (let loop ([column left])
          (when (<= column right)
            (put-character!
              frame clip top column
              (if (or (= column left) (= column right)) #\+ #\-)
              faces theme session-id key)
            (when (> bottom top)
              (put-character!
                frame clip bottom column
                (if (or (= column left) (= column right)) #\+ #\-)
                faces theme session-id key))
            (loop (+ column 1))))
        (let loop ([row (+ top 1)])
          (when (< row bottom)
            (put-character!
              frame clip row left #\| faces theme session-id key)
            (when (> right left)
              (put-character!
                frame clip row right #\| faces theme session-id key))
            (loop (+ row 1)))))))

  (define (paint-custom! node frame rect clip theme session-id)
    (when (and (positive? (rect-rows rect))
               (positive? (rect-columns rect)))
      (let ([local (make-frame (rect-rows rect) (rect-columns rect))])
        ((cdr (tui-node-content node))
         local
         (make-rect 0 0 (rect-rows rect) (rect-columns rect))
         theme
         session-id
         node)
        (do ([row 0 (+ row 1)])
            ((= row (rect-rows rect)))
          (do ([column 0 (+ column 1)])
              ((= column (rect-columns rect)))
            (let ([target-row (+ (rect-row rect) row)]
                  [target-column (+ (rect-column rect) column)]
                  [cell (frame-cell-ref local row column)])
              (when (and
                      (not (cell-continuation? cell))
                      (inside-frame? frame target-row target-column)
                      (inside-clip?
                        clip target-row target-column (cell-width cell)))
                (frame-put-cell!
                  frame target-row target-column cell))))))))

  (define (paint-arranged! arranged frame theme session-id clip)
    (let* ([node (tui-arranged-node-node arranged)]
           [rect (tui-arranged-node-rect arranged)]
           [node-clip (intersect-rect rect clip)]
           [faces
             (if (null? (tui-node-faces node))
                 '(application)
                 (tui-node-faces node))])
      (case (tui-node-kind node)
        [(text)
         (paint-string!
           frame rect node-clip (tui-node-content node)
           faces theme session-id (tui-node-key node))]
        [(styled-text)
         (let ([column (rect-column rect)])
           (for-each
             (lambda (span)
               (let* ([text (car span)]
                      [width (string-cell-width text 8)]
                      [span-rect
                        (make-rect
                          (rect-row rect) column (rect-rows rect)
                          (max 0
                            (min width
                                 (- (+ (rect-column rect)
                                       (rect-columns rect))
                                    column))))])
                 (paint-string!
                   frame span-rect node-clip text (cadr span)
                   theme session-id (tui-node-key node))
                 (set! column (+ column width))))
             (tui-node-content node)))]
        [(border)
         (paint-border!
           frame rect node-clip faces theme session-id (tui-node-key node))]
        [(custom)
         (paint-custom!
           node frame rect node-clip theme session-id)])
      (for-each
        (lambda (child)
          (paint-arranged! child frame theme session-id node-clip))
        (tui-arranged-node-children arranged))))

  (define (collect-focus-ring arranged clip parent-path)
    (let* ([node (tui-arranged-node-node arranged)]
           [path (append parent-path (list (tui-node-key node)))]
           [node-clip
             (intersect-rect (tui-arranged-node-rect arranged) clip)]
           [focus (tui-node-focus node)]
           [own
             (if (and focus
                      (tui-focus-focusable? focus)
                      (positive? (rect-rows node-clip))
                      (positive? (rect-columns node-clip)))
                 (list
                   (make-tui-focus-entry
                     (tui-node-key node)
                     node-clip
                     (or (tui-focus-order focus) 0)
                     (tui-focus-enabled? focus)
                     (tui-focus-group focus)
                     path))
                 '())])
      (append
        own
        (apply append
          (map (lambda (child) (collect-focus-ring child node-clip path))
               (tui-arranged-node-children arranged))))))

  (define (insert-focus-entry entry entries)
    (cond
      [(null? entries) (list entry)]
      [(< (tui-focus-entry-order entry)
          (tui-focus-entry-order (car entries)))
       (cons entry entries)]
      [else
       (cons (car entries)
             (insert-focus-entry entry (cdr entries)))]))

  (define (sort-focus-ring entries)
    (fold-left
      (lambda (result entry) (insert-focus-entry entry result))
      '()
      entries))

  (define (tui-render-surface node rows columns theme session-id cursor)
    (unless (and (tui-node? node)
                 (positive? rows)
                 (positive? columns)
                 (theme? theme)
                 (integer? session-id)
                 (exact? session-id)
                 (positive? session-id)
                 (or (not cursor) (tui-cursor? cursor)))
      (assertion-violation
        'tui-render-surface "invalid surface arguments"
        node rows columns theme session-id cursor))
    (let* ([frame (make-frame rows columns)]
           [arranged
             (tui-arrange node (make-rect 0 0 rows columns))])
      (frame-fill-rect!
        frame
        (make-rect 0 0 rows columns)
        (make-cell
          " "
          1
          '(application)
          (resolve-faces theme '(application))
          #f
          (list (make-cell-source 'application session-id (tui-node-key node)))))
      (let ([surface-rect (make-rect 0 0 rows columns)])
        (paint-arranged!
          arranged frame theme session-id surface-rect)
      (make-tui-surface
        rows columns frame
        (make-component-node
          (string->symbol
            (string-append "application." (number->string session-id)))
          (make-rect 0 0 rows columns)
          #f
          (list (arranged->component-tree arranged session-id '())))
          arranged
          (sort-focus-ring (collect-focus-ring arranged surface-rect '()))
          cursor))))
)
