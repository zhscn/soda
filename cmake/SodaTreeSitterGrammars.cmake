include_guard(GLOBAL)

macro(soda_fetch_tree_sitter_grammar dependency url sha256)
  FetchContent_Declare(
    ${dependency}
    URL "${url}"
    URL_HASH "SHA256=${sha256}"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR "__soda_source_only__"
  )
  FetchContent_MakeAvailable(${dependency})
endmacro()

soda_fetch_tree_sitter_grammar(
  tree_sitter_bash
  https://github.com/tree-sitter/tree-sitter-bash/archive/a06c2e4415e9bc0346c6b86d401879ffb44058f7.tar.gz
  879e8951ea2cc82455407e3eda0293319657ec53e83191e0fb5a67430d10d804
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_css
  https://github.com/tree-sitter/tree-sitter-css/archive/dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f.tar.gz
  c47392e483feb9137d8f0acf9ca6e916b820122c260324454a9980c75c98c3c5
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_go
  https://github.com/tree-sitter/tree-sitter-go/archive/2346a3ab1bb3857b48b29d779a1ef9799a248cd7.tar.gz
  94d08fc0f727a8dbe03203e2aaf1c5dc33a57e496b583049324eddc79769797b
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_html
  https://github.com/tree-sitter/tree-sitter-html/archive/73a3947324f6efddf9e17c0ea58d454843590cc0.tar.gz
  892f6b732e08bcb90918a985fdee58d6a0fd7a90326af601a2536a5d477583fa
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_javascript
  https://github.com/tree-sitter/tree-sitter-javascript/archive/58404d8cf191d69f2674a8fd507bd5776f46cb11.tar.gz
  f3e51e9f7b129f62a817551ae22a878dac5c18d71c456d5ad73e9c82d687f33d
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_json
  https://github.com/tree-sitter/tree-sitter-json/archive/refs/tags/v0.24.8.tar.gz
  acf6e8362457e819ed8b613f2ad9a0e1b621a77556c296f3abea58f7880a9213
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_lua
  https://github.com/tree-sitter-grammars/tree-sitter-lua/archive/10fe0054734eec83049514ea2e718b2a56acd0c9.tar.gz
  82c3ca5808de02addd9c7fb5275d89260c6557019aa6e40ca52c0595bf1d33cd
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_markdown
  https://github.com/tree-sitter-grammars/tree-sitter-markdown/archive/f969cd3ae3f9fbd4e43205431d0ae286014c05b5.tar.gz
  45ec28324b75ec80788775a6aed26888f55b306981fede9cbe35d7348ae80469
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_python
  https://github.com/tree-sitter/tree-sitter-python/archive/293fdc02038ee2bf0e2e206711b69c90ac0d413f.tar.gz
  b74d8ba6730535354175436208fe1452fd464f235263959ca40b8bf32cb23dc6
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_rust
  https://github.com/tree-sitter/tree-sitter-rust/archive/77a3747266f4d621d0757825e6b11edcbf991ca5.tar.gz
  dee82ddfd01bfc3a8ed201cc03b56448107d3217a4b3a7a8fc7fa6bc32b2405b
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_toml
  https://github.com/tree-sitter-grammars/tree-sitter-toml/archive/64b56832c2cffe41758f28e05c756a3a98d16f41.tar.gz
  feeb2e1cf531588cdcfb9c57292620151a08597f18a98dad26cc17fd4b544dcb
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_typescript
  https://github.com/tree-sitter/tree-sitter-typescript/archive/75b3874edb2dc714fb1fd77a32013d0f8699989f.tar.gz
  96ce4d1b513767d414bcca408efd9b49879162cceecdbed79a88e8ad2184f385
)
soda_fetch_tree_sitter_grammar(
  tree_sitter_yaml
  https://github.com/ikatyang/tree-sitter-yaml/archive/0e36bed171768908f331ff7dff9d956bae016efb.tar.gz
  46b6052ab86a14bb23406fbb5c56dc436798cb67b28a0e7fafe3183bc0c87788
)
