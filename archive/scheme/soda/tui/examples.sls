(library (soda tui examples)
  (export counter-example-definition
          counter-example-model?
          counter-example-model-value
          async-list-example-definition
          async-list-example-model?
          async-list-example-model-items
          async-list-example-model-selection
          async-list-example-model-loading?
          form-example-definition
          form-example-model?
          form-example-model-name
          form-example-model-email
          form-example-model-submitted?)
  (import (rnrs)
          (soda editor event)
          (soda editor tui-application)
          (soda tui application)
          (soda vfs))

  (define-record-type counter-example-model
    (fields value))

  (define (counter-delta payload)
    (cond
      [(eq? payload 'increment) 1]
      [(eq? payload 'decrement) -1]
      [(and (tui-input-event? payload)
            (memq (tui-input-event-kind payload)
                  '(key-press key-repeat))
            (key-event? (tui-input-event-value payload)))
       (case (key-event-key (tui-input-event-value payload))
         [(up) 1]
         [(down) -1]
         [else 0])]
      [else 0]))

  (define counter-example-definition
    (make-tui-application-definition
      'example.counter
      (lambda (context arguments)
        (values
          (make-counter-example-model
            (if (number? arguments) arguments 0))
          '()))
      (lambda (model message context)
        (tui-result
          (make-counter-example-model
            (+ (counter-example-model-value model)
               (counter-delta (tui-message-payload message))))
          '()
          '()))
      (lambda (model context)
        (tui-column
          'counter.root
          (list
            (tui-text
              'counter.title "Counter" '(application.heading))
            (tui-node-with-accessibility
              (tui-node-with-focus
                (tui-text
                  'counter.value
                  (number->string (counter-example-model-value model)))
                (make-tui-focus #t 'counter 0 #t))
              (make-tui-accessibility
                'value "Counter value"
                (number->string (counter-example-model-value model))
                "Use Up and Down to change the value."
                #f
                (number->string (counter-example-model-value model))
                '(edit.copy-region)
                #f)))))
      #f
      (lambda (model context)
        (number->string (counter-example-model-value model)))
      'fundamental-mode
      'edit
      '()
      '(editor.override)))

  (define-record-type async-list-example-model
    (fields path items selection viewport loading? error))

  (define (list-refresh-command path)
    (tui-command
      'directory.scan path 'session #f 'example.async-list.scan))

  (define (clamp-selection items selection)
    (if (null? items)
        0
        (min selection (- (length items) 1))))

  (define (move-list-selection model delta)
    (let* ([items (async-list-example-model-items model)]
           [count (length items)]
           [selection
             (if (zero? count)
                 0
                 (mod
                   (+ (async-list-example-model-selection model) delta)
                   count))])
      (make-async-list-example-model
        (async-list-example-model-path model)
        items
        selection
        selection
        (async-list-example-model-loading? model)
        (async-list-example-model-error model))))

  (define (runtime-list-value value)
    (cond
      [(and (tui-runtime-result? value)
            (zero? (tui-runtime-result-status value)))
       (map vfs-entry-name
            (decode-vfs-directory-entries
              (tui-runtime-result-data value)))]
      [(and (list? value) (for-all string? value)) value]
      [else #f]))

  (define async-list-example-definition
    (make-tui-application-definition
      'example.async-list
      (lambda (context arguments)
        (let ([path (if (string? arguments) arguments ".")])
          (values
            (make-async-list-example-model path '() 0 0 #t #f)
            (list (list-refresh-command path)))))
      (lambda (model message context)
        (let ([payload (tui-message-payload message)])
          (cond
            [(eq? payload 'next)
             (tui-result (move-list-selection model 1) '() '())]
            [(eq? payload 'previous)
             (tui-result (move-list-selection model -1) '() '())]
            [(eq? payload 'refresh)
             (tui-result
               (make-async-list-example-model
                 (async-list-example-model-path model)
                 (async-list-example-model-items model)
                 (async-list-example-model-selection model)
                 (async-list-example-model-viewport model)
                 #t #f)
               (list
                 (list-refresh-command
                   (async-list-example-model-path model)))
               '())]
            [(tui-command-result? payload)
             (let* ([value (tui-command-result-value payload)]
                    [items (runtime-list-value value)])
               (if items
                   (tui-result
                     (make-async-list-example-model
                       (async-list-example-model-path model)
                       items
                       (clamp-selection
                         items
                         (async-list-example-model-selection model))
                       0 #f #f)
                     '() '())
                   (tui-result
                     (make-async-list-example-model
                       (async-list-example-model-path model)
                       (async-list-example-model-items model)
                       (async-list-example-model-selection model)
                       (async-list-example-model-viewport model)
                       #f "Directory scan failed")
                     '() '())))]
            [else (tui-result model '() '())])))
      (lambda (model context)
        (let ([status
                (cond
                  [(async-list-example-model-loading? model) "Loading…"]
                  [(async-list-example-model-error model) => values]
                  [else
                   (string-append
                     (number->string
                       (length (async-list-example-model-items model)))
                     " entries")])])
          (tui-column
            'async-list.root
            (list
              (tui-text
                'async-list.title
                (async-list-example-model-path model)
                '(application.heading))
              (tui-node-with-layout
                (tui-scroll
                  'async-list.viewport
                  (tui-list
                    'async-list.items
                    (async-list-example-model-items model)
                    (and
                      (pair? (async-list-example-model-items model))
                      (async-list-example-model-selection model)))
                  (cons (async-list-example-model-viewport model) 0))
                (make-tui-layout (tui-flex 1) (tui-flex 1)))
              (tui-text 'async-list.status status '(application.status))))))
      #f
      (lambda (model context)
        (apply string-append
          (map
            (lambda (item) (string-append item "\n"))
            (async-list-example-model-items model))))
      'fundamental-mode
      'tools
      '(vfs)
      '(editor.override editor.default)))

  (define-record-type form-example-model
    (fields name email submitted?))

  (define (append-field model key text)
    (cond
      [(eq? key 'form.name)
       (make-form-example-model
         (string-append (form-example-model-name model) text)
         (form-example-model-email model)
         #f)]
      [(eq? key 'form.email)
       (make-form-example-model
         (form-example-model-name model)
         (string-append (form-example-model-email model) text)
         #f)]
      [else model]))

  (define (input-text payload)
    (and
      (tui-input-event? payload)
      (memq (tui-input-event-kind payload) '(text paste))
      (bytevector? (tui-input-event-value payload))
      (utf8->string (tui-input-event-value payload))))

  (define (form-field key label value order)
    (tui-column
      (list key 'container)
      (list
        (tui-text (list key 'label) label '(application.heading))
        (tui-node-with-accessibility
          (tui-node-with-focus
            (tui-text key value '(application))
            (make-tui-focus #t 'form order #t))
          (make-tui-accessibility
            'textbox label value #f value value '() #f)))))

  (define form-example-definition
    (make-tui-application-definition
      'example.form
      (lambda (context arguments)
        (values (make-form-example-model "" "" #f) '()))
      (lambda (model message context)
        (let* ([payload (tui-message-payload message)]
               [text (input-text payload)])
          (cond
            [text
             (tui-result
               (append-field
                 model
                 (tui-input-event-focused-node payload)
                 text)
               '() '())]
            [(eq? payload 'submit)
             (tui-result
               (make-form-example-model
                 (form-example-model-name model)
                 (form-example-model-email model)
                 #t)
               '() '())]
            [else (tui-result model '() '())])))
      (lambda (model context)
        (tui-column
          'form.root
          (list
            (tui-text 'form.title "Profile" '(application.heading))
            (form-field
              'form.name "Name" (form-example-model-name model) 0)
            (form-field
              'form.email "Email" (form-example-model-email model) 1)
            (tui-node-with-focus
              (tui-text
                'form.submit
                (if (form-example-model-submitted? model)
                    "Submitted"
                    "Submit"))
              (make-tui-focus #t 'form 2 #t)))))
      #f
      (lambda (model context)
        (string-append
          "Name: " (form-example-model-name model) "\n"
          "Email: " (form-example-model-email model) "\n"))
      'fundamental-mode
      'edit
      '()
      '(editor.override editor.default))))
