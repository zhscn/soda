-- The plugins the tests are written against, set up with the keys soda
-- had built in before they became plugins.
require("puni").setup()
for _, mode in ipairs({ "normal", "insert" }) do
  soda.map_default(mode, "<c-s-right>", "sexp-slurp")
  soda.map_default(mode, "<c-s-left>", "sexp-barf")
end
soda.map_default("insert", "<c-h>", "soft-backspace")
soda.map_default("normal", "<a-o>", "sexp-expand")

require("symbol-overlay").setup()
soda.map_default("global", "<c-c>i", "symbol-toggle")
soda.map_default("global", "<c-c>I", "symbol-clear")
soda.map_default("normal", "<a-n>", "symbol-switch-forward")
soda.map_default("normal", "<a-p>", "symbol-switch-backward")

require("surround").setup()
soda.map_default("global", "<c-c>g", "git-changes")

for key, command in pairs({
  ["."] = "lsp-implementation",
  k = "lsp-hover",
  c = "lsp-callers",
  C = "lsp-callees",
  t = "lsp-supertypes",
  T = "lsp-subtypes",
  R = "lsp-rename",
  a = "lsp-code-action",
  s = "lsp-symbols",
  S = "lsp-workspace-symbols",
  h = "lsp-switch",
}) do
  soda.map_default("lsp", "<c-c>" .. key, command)
end
