-- Marks the symbol at the caret wherever it occurs in the document, each in
-- a colour of its own, after Emacs's symbol-overlay. With the caret on a mark
-- single keys act on it, and mean what they always do elsewhere:
--
--   i  take the mark off           w  copy the symbol
--   n  next occurrence             e  back to where the last jump started
--   p  previous occurrence         d  go to the definition
--   <  first occurrence            s  search for the symbol
--   >  last occurrence             q  query replace it
--   h  list these keys             r  rename all its occurrences
--
-- A jump shows its place at the end of the line, as meow does: [3/12].
-- Built in: SPC i marks the symbol or takes its mark off; SPC I takes
-- off the marks of this document; <a-n> and <a-p> go to the nearest other
-- marked symbol. Those of the mark are in the `mark` context of `map`.

local COLOURS = 8
-- Mark colour by symbol, by buffer.
local marked = {}
-- Where the last jump started, by buffer.
local before = {}

local function marks(buf)
  marked[buf.id] = marked[buf.id] or {}
  return marked[buf.id]
end
local function pattern_of(word)
  return "\\b" .. word .. "\\b"
end
local function word_here()
  local found, word = pcall(soda.val, "word")
  return found and word or nil
end
local function require_word()
  local word = word_here()
  if not word then
    soda.message("No symbol here")
  end
  return word
end
-- The byte offsets where a symbol starts, in order.
local function occurrences(buf, word)
  local text, offsets, at = buf:text(), {}, 1
  local pattern = "%f[%w_]" .. word .. "%f[^%w_]"
  while true do
    local from, to = text:find(pattern, at)
    if not from then
      return offsets
    end
    table.insert(offsets, from)
    at = to + 1
  end
end
-- Which of the offsets the caret is on, and how far into the symbol.
local function place(buf, offsets, word)
  local _, head = buf:selection()
  local caret = buf:offset(head)
  for index, offset in ipairs(offsets) do
    if offset <= caret and caret <= offset + #word then
      return index, caret - offset
    end
  end
  return 1, 0
end
local function show_count(buf, index, total)
  local _, head = buf:selection()
  soda.indicator(head[1], "[" .. index .. "/" .. total .. "]")
end
local function move(buf, offset)
  local _, head = buf:selection()
  before[buf.id] = head
  buf:set_selection(buf:point(offset))
end
-- Moves to an occurrence chosen from the current one; the caret keeps its
-- place in the symbol.
local function jump(choose)
  local word = require_word()
  if not word then
    return
  end
  local buf = soda.buffer()
  local offsets = occurrences(buf, word)
  local index, within = place(buf, offsets, word)
  local target = choose(index, #offsets)
  move(buf, offsets[target] + within)
  show_count(buf, target, #offsets)
end

local function put(buf, word, colour)
  marks(buf)[word] = colour
  soda.command("highlight-local mark" .. colour .. " " .. pattern_of(word))
end
local function remove(buf, word)
  marks(buf)[word] = nil
  soda.command("unhighlight " .. pattern_of(word))
end
-- The first colour not in use, or the next in turn when all are.
local function free_colour(buf)
  local used, count = {}, 0
  for _, colour in pairs(marks(buf)) do
    used[colour] = true
    count = count + 1
  end
  for colour = 1, COLOURS do
    if not used[colour] then
      return colour
    end
  end
  return count % COLOURS + 1
end

soda.define_command("symbol-toggle", "Mark or unmark the symbol at the caret", function()
  local word = require_word()
  if not word then
    return
  end
  local buf = soda.buffer()
  if marks(buf)[word] then
    remove(buf, word)
  else
    put(buf, word, free_colour(buf))
    local offsets = occurrences(buf, word)
    show_count(buf, (place(buf, offsets, word)), #offsets)
  end
end)

soda.define_command("symbol-clear", "Unmark every symbol", function()
  local buf = soda.buffer()
  for word in pairs(marks(buf)) do
    remove(buf, word)
  end
end)

soda.define_command("symbol-jump-next", "Next occurrence of the marked symbol", function()
  jump(function(index, total)
    return index % total + 1
  end)
end)
soda.define_command("symbol-jump-prev", "Previous occurrence of the marked symbol", function()
  jump(function(index, total)
    return (index - 2) % total + 1
  end)
end)
soda.define_command("symbol-jump-first", "First occurrence of the marked symbol", function()
  jump(function()
    return 1
  end)
end)
soda.define_command("symbol-jump-last", "Last occurrence of the marked symbol", function(_)
  jump(function(_, total)
    return total
  end)
end)

-- Goes to the nearest occurrence of another marked symbol.
local function switch(forward)
  local buf = soda.buffer()
  local _, head = buf:selection()
  local caret = buf:offset(head)
  local current = word_here()
  local best, best_word
  for word in pairs(marks(buf)) do
    if word ~= current then
      for _, offset in ipairs(occurrences(buf, word)) do
        local ahead = offset > caret
        if ahead == forward and (not best or (offset < best) == forward) then
          best, best_word = offset, word
        end
      end
    end
  end
  if not best then
    soda.message("No more " .. (forward and "forward" or "backward") .. " symbols")
    return
  end
  move(buf, best)
  local offsets = occurrences(buf, best_word)
  show_count(buf, (place(buf, offsets, best_word)), #offsets)
end
soda.define_command("symbol-switch-forward", "Next occurrence of another marked symbol", function()
  switch(true)
end)
soda.define_command("symbol-switch-backward", "Previous occurrence of another marked symbol", function()
  switch(false)
end)

soda.define_command("symbol-echo-mark", "Go back to where the jump started", function()
  local buf = soda.buffer()
  local place_before = before[buf.id]
  if place_before then
    local _, head = buf:selection()
    before[buf.id] = head
    buf:set_selection(place_before)
  end
end)

soda.define_command("symbol-save", "Copy the symbol", function()
  local word = require_word()
  if word then
    soda.clipboard(word)
    soda.message("Copied " .. word)
  end
end)

soda.define_command("symbol-search", "Search for the symbol", function()
  local word = require_word()
  if word then
    soda.command("search")
    soda.keys(word)
  end
end)

soda.define_command("symbol-query-replace", "Query replace the symbol", function()
  local word = require_word()
  if word then
    soda.command("replace")
    soda.keys(word .. "<ret>")
  end
end)

soda.define_command("symbol-rename", "Rename every occurrence of the symbol", function(name)
  name = (name or ""):match("^%s*(.-)%s*$")
  local word = require_word()
  if not word then
    return
  end
  if name == "" then
    soda.prompt("symbol-rename " .. word)
    return
  end
  local buf = soda.buffer()
  if not name:match("^[%w_]+$") then
    soda.message("Not a symbol: " .. name)
    return
  end
  local changes = {}
  for _, offset in ipairs(occurrences(buf, word)) do
    table.insert(changes, { buf:point(offset), buf:point(offset + #word), name })
  end
  local offsets = occurrences(buf, word)
  local index = place(buf, offsets, word)
  local colour = marks(buf)[word]
  buf:edit(changes)
  -- The caret stands at the start of the symbol, as Emacs leaves it.
  buf:set_selection(buf:point(occurrences(buf, name)[index]))
  if colour then
    remove(buf, word)
    if marks(buf)[name] then
      remove(buf, name)
    end
    put(buf, name, colour)
  end
end)

soda.define_command("symbol-help", "Show the keys of a marked symbol", function()
  soda.popup(table.concat({
    "i  take the mark off      w  copy the symbol",
    "n  next occurrence        e  back to where the jump started",
    "p  previous occurrence    d  go to the definition",
    "<  first occurrence       s  search for the symbol",
    ">  last occurrence        q  query replace it",
    "h  these keys             r  rename all occurrences",
  }, "\n"))
end)

for key, command in pairs({
  i = "symbol-toggle",
  h = "symbol-help",
  n = "symbol-jump-next",
  p = "symbol-jump-prev",
  ["<lt>"] = "symbol-jump-first",
  ["<gt>"] = "symbol-jump-last",
  w = "symbol-save",
  e = "symbol-echo-mark",
  d = "lsp-definition",
  s = "symbol-search",
  q = "symbol-query-replace",
  r = "symbol-rename",
}) do
  soda.map("mark", key, command)
end
soda.map("global", "<c-c>i", "symbol-toggle")
soda.map("global", "<c-c>I", "symbol-clear")
soda.map("normal", "<a-n>", "symbol-switch-forward")
soda.map("normal", "<a-p>", "symbol-switch-backward")
