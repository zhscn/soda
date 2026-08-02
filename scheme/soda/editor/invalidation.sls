(library (soda editor invalidation)
  (export editor-invalidate!
          editor-take-dirty-reasons!)
  (import (rnrs)
          (soda editor editor-storage))

  (define (editor-invalidate! editor reason)
    (require-open-editor 'editor-invalidate! editor)
    (unless (symbol? reason)
      (assertion-violation
        'editor-invalidate!
        "dirty reason must be a symbol"
        reason))
    (editor-render-generation-set!
      editor
      (+ (editor-render-generation editor) 1))
    (unless (memq reason (editor-dirty-reasons editor))
      (editor-dirty-reasons-set!
        editor
        (append (editor-dirty-reasons editor) (list reason))))
    (editor-render-generation editor))

  (define (editor-take-dirty-reasons! editor)
    (require-open-editor 'editor-take-dirty-reasons! editor)
    (let ([reasons (editor-dirty-reasons editor)])
      (editor-dirty-reasons-set! editor '())
      reasons)))
