(library (soda editor tree-sitter-languages)
  (export built-in-tree-sitter-language-specs
          install-built-in-tree-sitter-languages!)
  (import (rnrs)
          (soda editor tree-sitter-language))

  (define common-pairs
    '((#\( . #\))
      (#\[ . #\])
      (#\{ . #\})))

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
        options)))

  (define (hidden-language-spec language)
    (make-tree-sitter-language-spec
      language
      language
      #f
      '()
      '((hidden? . #t))))

  (define built-in-tree-sitter-language-specs
    (list
      (language-spec 'ada '(".adb" ".ads" ".ada"))
      (language-spec 'astro '(".astro")
        '(settings . ((indent-width . 2))))
      (language-spec 'awk '(".awk" ".gawk" ".nawk" ".mawk")
        '(settings . ((indent-width . 2))))
      (language-spec
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
      (language-spec 'go '(".go"))
      (language-spec 'gomod '("go.mod")
        '(settings . ((indent-width . 2))))
      (language-spec 'gowork '("go.work")
        '(settings . ((indent-width . 2))))
      (language-spec 'gpr '(".gpr"))
      (language-spec 'haskell '(".hs" ".lhs"))
      (language-spec 'heex '(".heex" ".leex")
        '(settings . ((indent-width . 2))))
      (language-spec 'html '(".html" ".htm" ".shtml")
        '(settings . ((indent-width . 2))))
      (language-spec 'janet-simple '(".janet")
        '(settings . ((indent-width . 2))))
      (language-spec 'java '(".java"))
      (language-spec 'javascript '(".js" ".jsx" ".mjs" ".cjs")
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
          (queries . (highlights folds textobjects))))
      (language-spec 'julia '(".jl"))
      (language-spec 'kotlin '(".kt" ".kts"))
      (language-spec 'latex '(".tex" ".sty" ".cls"))
      (language-spec 'lua '(".lua")
        '(settings . ((indent-width . 2))))
      (language-spec 'magik '(".magik"))
      (language-spec
        'make
        '("Makefile" "makefile" "GNUmakefile" ".mk" ".mak"))
      (language-spec 'markdown '(".md" ".markdown" ".mdown"))
      (hidden-language-spec 'markdown-inline)
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
        '(".py" ".pyi" ".pyw" "SConstruct" "SConscript"))
      (language-spec 'r '(".r" ".R"))
      (language-spec
        'ruby
        '(".rb" ".rake" ".gemspec" "Gemfile" "Rakefile"))
      (language-spec 'rust '(".rs"))
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
      (language-spec 'toml '(".toml" "Cargo.lock" "Pipfile")
        '(settings . ((indent-width . 2))))
      (language-spec 'tsx '(".tsx")
        '(settings . ((indent-width . 2))))
      (language-spec 'typescript '(".ts" ".mts" ".cts")
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
      (language-spec 'yaml '(".yaml" ".yml")
        '(settings . ((indent-width . 2))))
      (language-spec 'zig '(".zig"))))

  (define (install-built-in-tree-sitter-languages! editor)
    (editor-register-tree-sitter-language-specs!
      editor
      built-in-tree-sitter-language-specs
      0)
    editor))
