(library (soda editor tree-sitter-languages)
  (export built-in-tree-sitter-language-specs
          install-built-in-tree-sitter-languages!)
  (import (rnrs)
          (soda editor tree-sitter-language))

  (define common-pairs
    '((#\( . #\))
      (#\[ . #\])
      (#\{ . #\})))

  (define line-comment-prefixes
    '((ada . "--") (awk . "#") (bash . "#")
      (c-sharp . "//") (c3 . "//") (clojure . ";;")
      (cmake . "#") (commonlisp . ";;") (dart . "//")
      (dockerfile . "#") (elisp . ";;") (elixir . "#")
      (erlang . "%") (gdscript . "#") (glsl . "//")
      (go . "//") (gomod . "//") (gowork . "//")
      (java . "//") (javascript . "//") (kotlin . "//")
      (lua . "--") (nix . "#") (nu . "#") (perl . "#")
      (php . "//") (proto . "//") (python . "#")
      (r . "#") (ruby . "#") (rust . "//")
      (scala . "//") (sql . "--") (toml . "#")
      (typescript . "//") (tsx . "//") (typst . "//")
      (yaml . "#")))

  (define block-comment-delimiters
    '((css "/*" "*/") (html "<!--" "-->")
      (javascript "/*" "*/") (typescript "/*" "*/")
      (tsx "{/*" "*/}") (go "/*" "*/")
      (rust "/*" "*/") (java "/*" "*/")
      (c-sharp "/*" "*/") (kotlin "/*" "*/")
      (glsl "/*" "*/")))

  (define (language-comment-settings language)
    (let ([line (assq language line-comment-prefixes)]
          [block (assq language block-comment-delimiters)])
      (append
        (if line
            (list (cons 'comment-line-prefix (cdr line)))
            '())
        (if block
            (list
              (cons 'comment-block-start (cadr block))
              (cons 'comment-block-end (caddr block)))
            '()))))

  (define (with-comment-settings language options)
    (let ([comments (language-comment-settings language)])
      (if
        (null? comments)
        options
        (let ([settings (assq 'settings options)])
          (if settings
              (map
                (lambda (entry)
                  (if (eq? (car entry) 'settings)
                      (cons 'settings (append (cdr entry) comments))
                      entry))
                options)
              (append options (list (cons 'settings comments))))))))

  (define (mode-name language)
    (string->symbol
      (string-append
        (symbol->string language)
        "-ts-mode")))

  (define (language-spec language suffixes . options)
    (make-tree-sitter-language-spec
      language
      language
      (mode-name language)
      suffixes
      (append
        `((pairs . ,common-pairs))
        (with-comment-settings language options))))

  (define (highlight-language-spec language suffixes . options)
    (apply
      language-spec
      language
      suffixes
      (cons '(queries . (highlights)) options)))

  (define (hidden-language-spec language . options)
    (make-tree-sitter-language-spec
      language
      language
      #f
      '()
      (cons '(hidden? . #t) options)))

  (define built-in-tree-sitter-language-specs
    (list
      (language-spec 'ada '(".adb" ".ads" ".ada"))
      (language-spec 'astro '(".astro")
        '(settings . ((indent-width . 2))))
      (language-spec 'awk '(".awk" ".gawk" ".nawk" ".mawk")
        '(settings . ((indent-width . 2))))
      (highlight-language-spec
        'bash
        '(".sh" ".bash" ".bashrc" ".bash_profile" ".profile")
        '(settings . ((indent-width . 2))))
      (language-spec 'bibtex '(".bib"))
      (language-spec 'bison '(".y" ".yy" ".yacc"))
      (language-spec 'c-sharp '(".cs" ".csx"))
      (language-spec 'c3 '(".c3"))
      (language-spec 'clojure '(".clj" ".cljs" ".cljc" ".edn")
        '(settings . ((indent-width . 2))))
      (language-spec 'cmake '("CMakeLists.txt" ".cmake")
        '(settings . ((indent-width . 2))))
      (language-spec 'commonlisp '(".lisp" ".lsp" ".cl")
        '(settings . ((indent-width . 2))))
      (language-spec 'css '(".css")
        '(queries . (highlights indents textobjects))
        '(settings . ((indent-width . 2))))
      (language-spec 'cylc '(".cylc")
        '(settings . ((indent-width . 4))))
      (language-spec 'dart '(".dart")
        '(settings . ((indent-width . 2))))
      (language-spec
        'dockerfile
        '("Dockerfile" ".dockerfile")
        '(settings . ((indent-width . 4))))
      (hidden-language-spec 'doxygen)
      (language-spec 'elisp '(".el")
        '(settings . ((indent-width . 2))))
      (language-spec 'elixir '(".ex" ".exs" ".elixir" "mix.lock")
        '(settings . ((indent-width . 2))))
      (language-spec 'erlang '(".erl" ".hrl"))
      (language-spec 'gdscript '(".gd"))
      (language-spec
        'glsl
        '(".glsl" ".vert" ".frag" ".geom" ".tesc" ".tese" ".comp"))
      (language-spec 'go '(".go")
        '(queries . (highlights indents textobjects)))
      (language-spec 'gomod '("go.mod")
        '(settings . ((indent-width . 2))))
      (language-spec 'gowork '("go.work")
        '(settings . ((indent-width . 2))))
      (language-spec 'gpr '(".gpr"))
      (language-spec 'haskell '(".hs" ".lhs"))
      (language-spec 'heex '(".heex" ".leex")
        '(settings . ((indent-width . 2))))
      (language-spec 'html '(".html" ".htm" ".shtml")
        '(queries . (highlights indents textobjects injections))
        '(settings . ((indent-width . 2))))
      (language-spec 'janet-simple '(".janet")
        '(settings . ((indent-width . 2))))
      (language-spec 'java '(".java"))
      (language-spec 'javascript '(".js" ".jsx" ".mjs" ".cjs")
        '(queries . (highlights indents textobjects))
        '(settings . ((indent-width . 2))))
      (hidden-language-spec 'jsdoc)
      (make-tree-sitter-language-spec
        'json
        'json
        'json-mode
        '(".json")
        `((pairs . ((#\[ . #\]) (#\{ . #\})))
          (identifier-character?
            . ,(lambda (character)
                 (or
                   (char-alphabetic? character)
                   (char-numeric? character)
                   (memv character '(#\_ #\-)))))
          (settings . ((indent-width . 2)))
          (queries . (highlights folds indents textobjects))))
      (language-spec 'julia '(".jl"))
      (language-spec 'kotlin '(".kt" ".kts"))
      (language-spec 'latex '(".tex" ".sty" ".cls"))
      (language-spec 'lua '(".lua")
        '(queries . (highlights indents textobjects))
        '(settings . ((indent-width . 2))))
      (language-spec 'magik '(".magik"))
      (language-spec
        'make
        '("Makefile" "makefile" "GNUmakefile" ".mk" ".mak"))
      (highlight-language-spec 'markdown '(".md" ".markdown" ".mdown"))
      (hidden-language-spec
        'markdown-inline
        '(queries . (highlights)))
      (language-spec 'nix '(".nix")
        '(settings . ((indent-width . 2))))
      (language-spec 'nu '(".nu")
        '(settings . ((indent-width . 2))))
      (language-spec 'org '(".org"))
      (language-spec 'p '(".p"))
      (language-spec 'perl '(".pl" ".pm" ".t"))
      (language-spec 'php '(".php" ".phtml" ".php3" ".php4" ".php5"))
      (language-spec 'proto '(".proto")
        '(settings . ((indent-width . 2))))
      (language-spec
        'python
        '(".py" ".pyi" ".pyw" "SConstruct" "SConscript")
        '(queries . (highlights indents textobjects))
        '(settings . ((indent-width . 4))))
      (language-spec 'r '(".r" ".R"))
      (language-spec
        'ruby
        '(".rb" ".rake" ".gemspec" "Gemfile" "Rakefile"))
      (language-spec 'rust '(".rs")
        '(queries . (highlights indents textobjects)))
      (language-spec 'scala '(".scala" ".sc")
        '(settings . ((indent-width . 2))))
      (language-spec 'scss '(".scss")
        '(settings . ((indent-width . 2))))
      (language-spec 'sdml '(".sdml"))
      (language-spec 'souffle '(".dl")
        '(settings . ((indent-width . 2))))
      (language-spec 'sql '(".sql")
        '(settings . ((indent-width . 2))))
      (language-spec 'surface '(".sface")
        '(settings . ((indent-width . 2))))
      (language-spec 'svelte '(".svelte")
        '(settings . ((indent-width . 2))))
      (highlight-language-spec 'toml '(".toml" "Cargo.lock" "Pipfile")
        '(settings . ((indent-width . 2))))
      (language-spec 'tsx '(".tsx")
        '(queries . (highlights indents textobjects))
        '(query-languages . (typescript tsx))
        '(settings . ((indent-width . 2))))
      (language-spec 'typescript '(".ts" ".mts" ".cts")
        '(queries . (highlights indents textobjects))
        '(settings . ((indent-width . 2))))
      (language-spec 'typst '(".typ")
        '(settings . ((indent-width . 2))))
      (language-spec 'vala '(".vala" ".vapi"))
      (language-spec 'verilog '(".v" ".vh" ".sv" ".svh"))
      (language-spec 'vhdl '(".vhd" ".vhdl"))
      (language-spec 'wast '(".wast"))
      (language-spec 'wat '(".wat"))
      (language-spec 'wgsl '(".wgsl")
        '(settings . ((indent-width . 2))))
      (highlight-language-spec 'yaml '(".yaml" ".yml")
        '(settings . ((indent-width . 2))))
      (language-spec 'zig '(".zig"))))

  (define (install-built-in-tree-sitter-languages! editor)
    (editor-register-tree-sitter-language-specs!
      editor
      built-in-tree-sitter-language-specs
      0)
    editor))
