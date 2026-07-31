(library (soda editor mode-runtime)
  (export buffer-major-mode-feature
          buffer-major-mode-function
          call-buffer-major-mode-function)
  (import (rnrs)
          (soda editor buffer)
          (soda editor language))

  (define (buffer-major-mode-feature buffer name default)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-major-mode-feature
        "expected a buffer"
        buffer))
    (major-mode-feature-ref
      (buffer-language-catalog buffer)
      (buffer-major-mode-name buffer)
      name
      default))

  (define (buffer-major-mode-function buffer name default)
    (unless (or (not default) (procedure? default))
      (assertion-violation
        'buffer-major-mode-function
        "default must be a procedure or #f"
        default))
    (let ([value
            (buffer-major-mode-feature buffer name default)])
      (unless (or (not value) (procedure? value))
        (assertion-violation
          'buffer-major-mode-function
          "major mode feature must be a procedure or #f"
          name
          value))
      value))

  (define (call-buffer-major-mode-function
            buffer name default . arguments)
    (let ([procedure
            (buffer-major-mode-function buffer name default)])
      (and procedure (apply procedure arguments)))))
