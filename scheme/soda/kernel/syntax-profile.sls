(library (soda kernel syntax-profile)
  (export make-syntax-profile
          syntax-profile?
          syntax-profile-name
          syntax-profile-classifier
          syntax-profile-delimiter-pairs
          syntax-profile-line-comment-starts
          syntax-profile-block-comment-pairs
          syntax-profile-string-delimiters
          syntax-profile-escape-character
          syntax-profile-classify
          syntax-profile-word-constituent?
          syntax-profile-delimiter-pair
          syntax-profile-open-delimiter?
          syntax-profile-close-delimiter?
          make-plain-text-syntax-profile
          buffer-syntax-profile-facet
          make-buffer-syntax-profile-extension)
  (import (rnrs)
          (only (chezscheme) string->immutable-string)
          (soda kernel extension)
          (soda kernel value))

  (define-record-type
    (syntax-profile %make-syntax-profile syntax-profile?)
    (fields (immutable name syntax-profile-name)
            (immutable classifier syntax-profile-classifier)
            (immutable delimiter-pairs syntax-profile-delimiter-pairs)
            (immutable line-comment-starts syntax-profile-line-comment-starts)
            (immutable block-comment-pairs syntax-profile-block-comment-pairs)
            (immutable string-delimiters syntax-profile-string-delimiters)
            (immutable escape-character syntax-profile-escape-character)))

  (define (character-pair? value)
    (and (pair? value) (char? (car value)) (char? (cdr value))))

  (define (string-pair? value)
    (and (pair? value) (string? (car value)) (string? (cdr value))))

  (define (immutable-string value)
    (string->immutable-string (string-copy value)))

  (define (make-syntax-profile name classifier delimiter-pairs line-comments
                               block-comments string-delimiters escape-character)
    (unless (and (symbol? name) (procedure? classifier)
                 (list? delimiter-pairs) (for-all character-pair? delimiter-pairs)
                 (list? line-comments) (for-all string? line-comments)
                 (list? block-comments) (for-all string-pair? block-comments)
                 (list? string-delimiters) (for-all char? string-delimiters)
                 (or (not escape-character) (char? escape-character)))
      (assertion-violation 'make-syntax-profile "invalid syntax profile" name))
    (%make-syntax-profile
      name classifier
      (map (lambda (pair) (cons (car pair) (cdr pair))) delimiter-pairs)
      (map immutable-string line-comments)
      (map (lambda (pair)
             (cons (immutable-string (car pair))
                   (immutable-string (cdr pair))))
           block-comments)
      (list-copy string-delimiters) escape-character))

  (define (syntax-profile-classify profile character)
    (unless (and (syntax-profile? profile) (char? character))
      (assertion-violation 'syntax-profile-classify
                           "expected a SyntaxProfile and character"
                           profile character))
    (let ([class ((syntax-profile-classifier profile) character)])
      (unless (memq class '(whitespace word symbol punctuation))
        (assertion-violation 'syntax-profile-classify
                             "classifier returned an invalid syntax class"
                             class character))
      class))

  (define (syntax-profile-word-constituent? profile character)
    (memq (syntax-profile-classify profile character) '(word symbol)))

  (define (syntax-profile-delimiter-pair profile character)
    (unless (and (syntax-profile? profile) (char? character))
      (assertion-violation 'syntax-profile-delimiter-pair
                           "expected a SyntaxProfile and character"
                           profile character))
    (find (lambda (pair)
            (or (char=? character (car pair))
                (char=? character (cdr pair))))
          (syntax-profile-delimiter-pairs profile)))

  (define (syntax-profile-open-delimiter? profile character)
    (let ([pair (syntax-profile-delimiter-pair profile character)])
      (and pair (char=? character (car pair)))))

  (define (syntax-profile-close-delimiter? profile character)
    (let ([pair (syntax-profile-delimiter-pair profile character)])
      (and pair (char=? character (cdr pair)))))

  (define (plain-classifier character)
    (let ([category (char-general-category character)])
      (cond
        [(char-whitespace? character) 'whitespace]
        [(or (char-alphabetic? character) (char-numeric? character)
             (memq category '(Mn Mc Me Pc)))
         'word]
        [else 'punctuation])))

  (define (make-plain-text-syntax-profile)
    (make-syntax-profile
      'plain-text plain-classifier
      (list (cons #\( #\)) (cons #\[ #\]) (cons #\{ #\}))
      '() '() (list #\") #\\))

  (define (last-value values)
    (and (pair? values)
         (let loop ([remaining (cdr values)] [result (car values)])
           (if (null? remaining) result
               (loop (cdr remaining) (car remaining))))))

  (define buffer-syntax-profile-facet
    (make-facet 'buffer-syntax-profile 'buffer #f last-value eq? eq?))

  (define (make-buffer-syntax-profile-extension profile)
    (unless (syntax-profile? profile)
      (assertion-violation 'make-buffer-syntax-profile-extension
                           "expected a SyntaxProfile" profile))
    (make-facet-provider buffer-syntax-profile-facet profile))
)
