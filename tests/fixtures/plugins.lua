-- The plugins the tests are written against, set up with the keys soda
-- had built in before they became plugins.
require("puni").setup()
for _, mode in ipairs({ "normal", "insert" }) do
  soda.map_default(mode, "C-S-<right>", "sexp-slurp")
  soda.map_default(mode, "C-S-<left>", "sexp-barf")
end
soda.map_default("insert", "C-h", "soft-backspace")
soda.map_default("normal", "M-o", "sexp-expand")

require("symbol-overlay").setup()
soda.map_default("global", "C-c i", "symbol-toggle")
soda.map_default("global", "C-c I", "symbol-clear")
soda.map_default("normal", "M-n", "symbol-switch-forward")
soda.map_default("normal", "M-p", "symbol-switch-backward")

require("surround").setup()
soda.map_default("global", "C-c g", "git-changes")

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
  soda.map_default("lsp", "C-c " .. key, command)
end
