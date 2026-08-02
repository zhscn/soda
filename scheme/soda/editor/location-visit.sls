(library (soda editor location-visit)
  (export location-item-open-position
          editor-visit-location-item!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor condition)
          (soda editor file)
          (soda editor location)
          (soda editor navigation)
          (soda editor resource-context)
          (soda editor state))

  (define (location-item-open-position item)
    (let ([metadata (location-item-metadata item)])
      (let ([entry
              (and (list? metadata)
                   (assq 'file-open-position metadata))])
        (and entry
             (file-utf16-position? (cdr entry))
             (cdr entry)))))

  (define (location-item-open-end-position item)
    (let ([metadata (location-item-metadata item)])
      (let ([entry
              (and (list? metadata)
                   (assq 'file-open-end-position metadata))])
        (and entry
             (file-utf16-position? (cdr entry))
             (cdr entry)))))

  (define (item-resource-context editor view item)
    (let ([base
            (editor-view-resource-context editor (view-id view))]
          [language-context (location-item-language-context item)])
      (if language-context
          (resource-context-with-language-context base language-context)
          base)))

  (define (%editor-visit-location-item!
            editor view item kind display-intent)
    (unless (and (editor? editor)
                 (view? view)
                 (location-item? item)
                 (symbol? kind)
                 (or (not display-intent)
                     (memq display-intent '(edit jump tools doc pop))))
      (assertion-violation
        'editor-visit-location-item!
        "invalid location visit request"
        editor view item kind))
    (let ([buffer-id (location-item-buffer-id item)]
          [context (item-resource-context editor view item)])
      (if buffer-id
          (let ([buffer (editor-buffer-ref editor buffer-id)])
            (unless (= (buffer-revision buffer)
                       (location-item-revision item))
              (editor-user-error
                'location.visit
                "Location is stale"
                (location-item-revision item)
                (buffer-revision buffer)))
            (editor-jump-view-to-buffer!
              editor view buffer (location-item-start item) kind)
            (view-set-navigation-target!
              view
              (location-item-start item)
              (location-item-end item)
              kind)
            '())
          (let ([resource (location-item-resource item)]
                [position
                  (or (location-item-open-position item)
                      (location-item-start item))]
                [end-position
                  (or
                    (location-item-open-end-position item)
                    (and
                      (> (location-item-end item)
                         (location-item-start item))
                      (location-item-end item)))])
            (unless (string? resource)
              (editor-user-error
                'location.visit "Location has no resource"))
            (editor-begin-async-jump! editor view resource kind)
            (list
              (make-command-effect
                'file.read
                (make-open-request
                  (view-id view)
                  resource
                  position
                  display-intent
                  context
                  (and
                    (not display-intent)
                    end-position
                    (make-file-navigation-target
                      position end-position kind)))))))))

  (define editor-visit-location-item!
    (case-lambda
      [(editor view item kind)
       (%editor-visit-location-item! editor view item kind 'jump)]
      [(editor view item kind display-intent)
       (%editor-visit-location-item!
         editor view item kind display-intent)]))
)
