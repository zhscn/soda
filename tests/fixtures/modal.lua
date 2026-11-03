-- The modal setup the tests are written against: meow with the layout and
-- leader keys soda had built in before meow became a plugin.
require("meow").setup({
  layout = {
    h = "left", j = "down", k = "up", l = "right",
    H = "left-expand", J = "down-expand", K = "up-expand", L = "right-expand",
    w = "next-word", b = "back-word", W = "next-symbol", B = "back-symbol",
    ["["] = "mark-word", ["]"] = "mark-symbol",
    e = "select-line", o = "block", O = "to-block",
    f = "find", t = "till",
    [","] = "inner-of-thing", ["."] = "bounds-of-thing",
    [";"] = "reverse", z = "pop-selection", Z = "pop-all-selection",
    ["-"] = "negative-argument",
    ["0"] = "expand 0", ["1"] = "expand 1", ["2"] = "expand 2", ["3"] = "expand 3",
    ["4"] = "expand 4", ["5"] = "expand 5", ["6"] = "expand 6", ["7"] = "expand 7",
    ["8"] = "expand 8", ["9"] = "expand 9",
    i = "insert", a = "append", A = "open-below", I = "open-above",
    r = "kill", s = "change", d = "delete", y = "save", p = "put",
    ["'"] = "join",
    n = "search-next", N = "search-pop", v = "visit",
    u = "undo", U = "redo",
    q = "jump-to", Q = "goto", R = "replace", ["/"] = "open",
    ["`"] = "repeat",
    G = "grab", S = "swap-grab", E = "macro-lines", V = "macro-matches",
    x = "keypad <c-x>", c = "keypad <c-c>", m = "keypad meta", g = "keypad ctrl-meta",
    ["<space>"] = "keypad leader",
  },
  things = { a = "angle" },
})
for key, command in pairs({
  f = "project",
  b = "buffer",
  r = "recent",
  [":"] = "commands",
  j = "jump-to",
  o = "window-pick",
  w = "window-pick",
  H = "window-left",
  J = "window-down",
  K = "window-up",
  L = "window-right",
  W = "resize-window",
  ["["] = "macro-start",
  ["]"] = "macro-end",
}) do
  soda.map_default("global", "<c-c>" .. key, command)
end
for digit = 0, 9 do
  soda.map_default("global", "<c-c>" .. digit, "digit-argument " .. digit)
end
soda.map_default("global", "<c-x><c-o>", "window-pick")
