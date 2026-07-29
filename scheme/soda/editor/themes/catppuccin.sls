(library (soda editor themes catppuccin)
  (export catppuccin-latte
          catppuccin-frappe
          catppuccin-macchiato
          catppuccin-mocha
          catppuccin-themes
          default-theme
          make-default-theme-catalog)
  (import (rnrs)
          (soda editor theme))

  (define (rgb red green blue)
    (vector red green blue))

  (define (palette-ref palette name)
    (cond
      [(assq name palette) => cdr]
      [else
       (assertion-violation
         'palette-ref
         "Catppuccin palette color is not defined"
         name)]))

  (define (face foreground background attributes)
    (make-face-spec foreground background attributes '()))

  (define (palette-face palette foreground background attributes)
    (face
      (if (and
            (symbol? foreground)
            (not (memq foreground '(inherit default))))
          (palette-ref palette foreground)
          foreground)
      (if (and
            (symbol? background)
            (not (memq background '(inherit default))))
          (palette-ref palette background)
          background)
      attributes))

  (define (make-catppuccin-theme name appearance palette)
    (define (pface foreground background attributes)
      (palette-face palette foreground background attributes))
    (make-theme
      name
      appearance
      0
      (list
        (cons 'default (pface 'text 'base '()))
        (cons 'modeline (pface 'text 'surface0 '(bold)))
        (cons 'minibuffer-prompt (pface 'mauve 'base '(bold)))
        (cons 'completion-selected (pface 'text 'surface1 '(bold)))
        (cons 'selection (pface 'inherit 'surface2 '()))
        (cons 'line-number (pface 'overlay0 'base '()))
        (cons 'syntax-comment (pface 'overlay1 'inherit '(italic)))
        (cons 'syntax-string (pface 'green 'inherit '()))
        (cons 'syntax-constant (pface 'peach 'inherit '()))
        (cons 'syntax-number (pface 'peach 'inherit '()))
        (cons 'syntax-keyword (pface 'mauve 'inherit '(bold)))
        (cons 'syntax-builtin (pface 'blue 'inherit '()))
        (cons 'syntax-definition (pface 'blue 'inherit '(bold)))
        (cons 'syntax-type (pface 'yellow 'inherit '()))
        (cons 'syntax-delimiter (pface 'overlay2 'inherit '()))
        (cons 'syntax-preprocessor (pface 'mauve 'inherit '()))
        (cons 'syntax-invalid (pface 'red 'inherit '(underline)))
        (cons 'diagnostic-error (pface 'red 'inherit '(underline)))
        (cons 'diagnostic-warning (pface 'yellow 'inherit '(underline)))
        (cons 'diagnostic-info (pface 'sapphire 'inherit '(underline)))
        (cons 'diagnostic-hint (pface 'teal 'inherit '(underline)))
        (cons 'completion-match (pface 'blue 'inherit '(bold))))))

  (define latte-palette
    (list
      (cons 'red (rgb #xd2 #x0f #x39))
      (cons 'peach (rgb #xfe #x64 #x0b))
      (cons 'yellow (rgb #xdf #x8e #x1d))
      (cons 'green (rgb #x40 #xa0 #x2b))
      (cons 'teal (rgb #x17 #x92 #x99))
      (cons 'sapphire (rgb #x20 #x9f #xb5))
      (cons 'blue (rgb #x1e #x66 #xf5))
      (cons 'mauve (rgb #x88 #x39 #xef))
      (cons 'text (rgb #x4c #x4f #x69))
      (cons 'overlay2 (rgb #x7c #x7f #x93))
      (cons 'overlay1 (rgb #x8c #x8f #xa1))
      (cons 'overlay0 (rgb #x9c #xa0 #xb0))
      (cons 'surface2 (rgb #xac #xb0 #xbe))
      (cons 'surface1 (rgb #xbc #xc0 #xcc))
      (cons 'surface0 (rgb #xcc #xd0 #xda))
      (cons 'base (rgb #xef #xf1 #xf5))))

  (define frappe-palette
    (list
      (cons 'red (rgb #xe7 #x82 #x84))
      (cons 'peach (rgb #xef #x9f #x76))
      (cons 'yellow (rgb #xe5 #xc8 #x90))
      (cons 'green (rgb #xa6 #xd1 #x89))
      (cons 'teal (rgb #x81 #xc8 #xbe))
      (cons 'sapphire (rgb #x85 #xc1 #xdc))
      (cons 'blue (rgb #x8c #xaa #xee))
      (cons 'mauve (rgb #xca #x9e #xe6))
      (cons 'text (rgb #xc6 #xd0 #xf5))
      (cons 'overlay2 (rgb #x94 #x9c #xbb))
      (cons 'overlay1 (rgb #x83 #x8b #xa7))
      (cons 'overlay0 (rgb #x73 #x79 #x94))
      (cons 'surface2 (rgb #x62 #x68 #x80))
      (cons 'surface1 (rgb #x51 #x57 #x6d))
      (cons 'surface0 (rgb #x41 #x45 #x59))
      (cons 'base (rgb #x30 #x34 #x46))))

  (define macchiato-palette
    (list
      (cons 'red (rgb #xed #x87 #x96))
      (cons 'peach (rgb #xf5 #xa9 #x7f))
      (cons 'yellow (rgb #xee #xd4 #x9f))
      (cons 'green (rgb #xa6 #xda #x95))
      (cons 'teal (rgb #x8b #xd5 #xca))
      (cons 'sapphire (rgb #x7d #xc4 #xe4))
      (cons 'blue (rgb #x8a #xad #xf4))
      (cons 'mauve (rgb #xc6 #xa0 #xf6))
      (cons 'text (rgb #xca #xd3 #xf5))
      (cons 'overlay2 (rgb #x93 #x9a #xb7))
      (cons 'overlay1 (rgb #x80 #x87 #xa2))
      (cons 'overlay0 (rgb #x6e #x73 #x8d))
      (cons 'surface2 (rgb #x5b #x60 #x78))
      (cons 'surface1 (rgb #x49 #x4d #x64))
      (cons 'surface0 (rgb #x36 #x3a #x4f))
      (cons 'base (rgb #x24 #x27 #x3a))))

  (define mocha-palette
    (list
      (cons 'red (rgb #xf3 #x8b #xa8))
      (cons 'peach (rgb #xfa #xb3 #x87))
      (cons 'yellow (rgb #xf9 #xe2 #xaf))
      (cons 'green (rgb #xa6 #xe3 #xa1))
      (cons 'teal (rgb #x94 #xe2 #xd5))
      (cons 'sapphire (rgb #x74 #xc7 #xec))
      (cons 'blue (rgb #x89 #xb4 #xfa))
      (cons 'mauve (rgb #xcb #xa6 #xf7))
      (cons 'text (rgb #xcd #xd6 #xf4))
      (cons 'overlay2 (rgb #x93 #x99 #xb2))
      (cons 'overlay1 (rgb #x7f #x84 #x9c))
      (cons 'overlay0 (rgb #x6c #x70 #x86))
      (cons 'surface2 (rgb #x58 #x5b #x70))
      (cons 'surface1 (rgb #x45 #x47 #x5a))
      (cons 'surface0 (rgb #x31 #x32 #x44))
      (cons 'base (rgb #x1e #x1e #x2e))))

  (define catppuccin-latte
    (make-catppuccin-theme 'catppuccin-latte 'light latte-palette))

  (define catppuccin-frappe
    (make-catppuccin-theme 'catppuccin-frappe 'dark frappe-palette))

  (define catppuccin-macchiato
    (make-catppuccin-theme 'catppuccin-macchiato 'dark macchiato-palette))

  (define catppuccin-mocha
    (make-catppuccin-theme 'catppuccin-mocha 'dark mocha-palette))

  (define catppuccin-themes
    (list
      catppuccin-latte
      catppuccin-frappe
      catppuccin-macchiato
      catppuccin-mocha))

  (define default-theme catppuccin-mocha)

  (define (make-default-theme-catalog)
    (make-theme-catalog catppuccin-themes)))
