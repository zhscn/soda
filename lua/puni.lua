-- puni's keys for the structural commands of `pairs`: deletion and
-- killing that keep brackets and quotes paired. Off until setup:
--
--   require("puni").setup()
--   require("puni").setup({ keys = false })   -- the commands alone
--
-- As puni-mode-map: Backspace deletes without breaking a pair, M-Backspace
-- cuts a word without breaking one, C-k kills to the line end or to the
-- end of the group, C-w cuts the selection or else a word, C-M-a and C-M-e
-- go to the start and end of the group. The commands are there without
-- setup; sexp-slurp and sexp-barf have no keys, as in puni.

local M = {}

local INSERT = {
  ["<bs>"] = "soft-backspace",
  ["<a-bs>"] = "soft-kill-word",
  ["<c-bs>"] = "soft-kill-word",
  ["<c-w>"] = "kill-region-or-word",
}
local EVERY_MODE = {
  ["<c-k>"] = "sexp-kill",
  ["<c-a-a>"] = "sexp-beginning",
  ["<c-a-e>"] = "sexp-end",
}

function M.setup(options)
  options = options or {}
  if options.keys == false then
    return
  end
  for key, command in pairs(INSERT) do
    soda.map_default("insert", key, command)
  end
  for key, command in pairs(EVERY_MODE) do
    soda.map_default("insert", key, command)
    soda.map_default("normal", key, command)
  end
end

return M
