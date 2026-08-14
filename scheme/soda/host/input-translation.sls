(library (soda host input-translation)
  (export make-input-translation
          input-translation?
          input-translation-translate
          input-translation-aliases
          identity-input-translation)
  (import (rnrs)
          (soda host input-event))

  ;; InputTranslation keeps frontend key reporting separate from application
  ;; key syntax.  Translation supplies the canonical resolver sequence;
  ;; aliases supply equivalent user-facing sequences for introspection.
  (define-record-type
    (input-translation %make-input-translation input-translation?)
    (fields
      (immutable translate input-translation-translate-procedure)
      (immutable aliases input-translation-aliases-procedure)))

  (define (key-stroke-sequence? value)
    (and (list? value) (for-all key-stroke? value)))

  (define (make-input-translation translate aliases)
    (unless (and (procedure? translate) (procedure? aliases))
      (assertion-violation
        'make-input-translation "expected translate and alias procedures"
        translate aliases))
    (%make-input-translation translate aliases))

  (define (input-translation-translate translation sequence)
    (unless (and (input-translation? translation)
                 (key-stroke-sequence? sequence))
      (assertion-violation
        'input-translation-translate
        "expected an InputTranslation and KeyStroke sequence"
        translation sequence))
    (let ([translated
           ((input-translation-translate-procedure translation) sequence)])
      (unless (key-stroke-sequence? translated)
        (assertion-violation
          'input-translation-translate
          "translation returned an invalid KeyStroke sequence"
          translated))
      translated))

  (define (input-translation-aliases translation sequence)
    (unless (and (input-translation? translation)
                 (key-stroke-sequence? sequence))
      (assertion-violation
        'input-translation-aliases
        "expected an InputTranslation and KeyStroke sequence"
        translation sequence))
    (let ([aliases
           ((input-translation-aliases-procedure translation) sequence)])
      (unless (and (list? aliases) (for-all key-stroke-sequence? aliases))
        (assertion-violation
          'input-translation-aliases
          "translation returned invalid KeyStroke sequence aliases"
          aliases))
      aliases))

  (define identity-input-translation
    (make-input-translation
      (lambda (sequence) (map (lambda (stroke) stroke) sequence))
      (lambda (sequence)
        (list (map (lambda (stroke) stroke) sequence)))))
)
