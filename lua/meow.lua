-- Modal editing after meow: Normal selects first and acts on the
-- selection, Insert types, Beacon edits many selections at once. Off until
-- setup turns it on; without it soda edits as Emacs does, in Insert alone.
--
--   require("meow").setup()                         -- meow's QWERTY layout
--   require("meow").setup({ layout = { h = "left", ... } })
--   require("meow").setup({ layout = false })       -- bind Normal yourself
--
-- Options:
--   layout  "qwerty" (default), a table of key = command for Normal, or
--           false. meow has no keys of its own either: its README gives a
--           layout to copy, and "qwerty" is that one, less the commands
--           soda lacks (beginning-of-thing, end-of-thing, backward-delete,
--           quit, replace, undo-in-selection, sync-grab).
--   things  extra keys for `,` and `.`, as { a = "angle" }; see soda.thing.
--
-- The modal machinery is the editor's: setup sets the `modal` option, which
-- makes Normal the mode between insertions and names the mode on the
-- status line. Normal's keys that type no character (C-f, arrows, Esc,
-- Enter) are built in; a layout gives those that do.

local M = {}

M.layouts = {
  qwerty = {
    ["0"] = "expand 0",
    ["1"] = "expand 1",
    ["2"] = "expand 2",
    ["3"] = "expand 3",
    ["4"] = "expand 4",
    ["5"] = "expand 5",
    ["6"] = "expand 6",
    ["7"] = "expand 7",
    ["8"] = "expand 8",
    ["9"] = "expand 9",
    ["-"] = "negative-argument",
    [";"] = "reverse",
    [","] = "inner-of-thing",
    ["."] = "bounds-of-thing",
    a = "append",
    A = "open-below",
    b = "back-word",
    B = "back-symbol",
    c = "change",
    d = "delete",
    e = "next-word",
    E = "next-symbol",
    f = "find",
    g = "cancel",
    G = "grab",
    h = "left",
    H = "left-expand",
    i = "insert",
    I = "open-above",
    j = "down",
    J = "down-expand",
    k = "up",
    K = "up-expand",
    l = "right",
    L = "right-expand",
    m = "join",
    n = "search-next",
    o = "block",
    O = "to-block",
    p = "put",
    Q = "goto",
    R = "swap-grab",
    s = "kill",
    t = "till",
    u = "undo",
    v = "visit",
    w = "mark-word",
    W = "mark-symbol",
    x = "select-line",
    X = "goto",
    y = "save",
    z = "pop-selection",
    ["'"] = "repeat",
    ["<space>"] = "keypad leader",
  },
}

-- Binds a layout's keys in Normal.
function M.bind(layout)
  for key, command in pairs(layout) do
    soda.map_default("normal", key, command)
  end
end

function M.setup(options)
  options = options or {}
  local layout = options.layout
  if layout == nil then
    layout = "qwerty"
  end
  if type(layout) == "string" then
    layout = M.layouts[layout] or error("meow: no layout called " .. layout, 2)
  end
  if layout then
    M.bind(layout)
  end
  for key, kind in pairs(options.things or {}) do
    soda.thing(key, kind)
  end
  soda.set("modal", true)
end

-- Back to editing in Insert alone; the keys stay bound, unused.
function M.disable()
  soda.set("modal", false)
end

return M
