-- Emacs editing commands: word case, transposing
-- and whitespace. Moves and the C-x keys are built into the key tables.
--
-- Built in: <a-u> <a-l> <a-c> <a-t> <a-\> <a-space> <a-^> and <c-t> in Normal
-- and Insert; <c-o> and <a-m> in Insert.

local WORD = "[%w_\128-\255]+"
local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function caret(buf)
  local _, head = buf:selection()
  return head[1], head[2], buf:line(head[1])
end

-- The character starting before byte `at`, as its first byte.
local function char_before(text, at)
  local start = at - 1
  while start > 1 and text:byte(start) >= 128 and text:byte(start) < 192 do
    start = start - 1
  end
  return start
end

local function change_word(change)
  return function()
    local buf = soda.buffer()
    local line, column, text = caret(buf)
    local from, to = text:find(WORD, column)
    if not from then
      soda.message("No word after the caret")
      return
    end
    buf:edit({ { { line, from }, { line, to + 1 }, change(text:sub(from, to)) } })
    buf:set_selection({ line, to + 1 })
  end
end
soda.define_command(
  "upcase-word",
  "Upcase the word after the caret",
  change_word(string.upper)
)
soda.define_command(
  "downcase-word",
  "Downcase the word after the caret",
  change_word(string.lower)
)
soda.define_command(
  "capitalize-word",
  "Capitalize the word after the caret",
  change_word(function(word)
    return word:lower():gsub("^[^%a]*%a", string.upper)
  end)
)

soda.define_command("transpose-chars", "Swap the characters around the caret", function()
  local buf = soda.buffer()
  local line, column, text = caret(buf)
  if column > #text then
    column = column > 1 and char_before(text, column) or column
  end
  if column <= 1 or column > #text then
    soda.message("Nothing to transpose")
    return
  end
  local from = char_before(text, column)
  local after = text:match(CHAR, column)
  local to = column + #after
  buf:edit({ { { line, from }, { line, to }, after .. text:sub(from, column - 1) } })
  buf:set_selection({ line, to })
end)

soda.define_command("transpose-words", "Swap the words around the caret", function()
  local buf = soda.buffer()
  local line, column, text = caret(buf)
  local words, first = {}, 1
  for from, to in text:gmatch("()" .. WORD .. "()") do
    table.insert(words, { from, to })
    if from < column then
      first = #words
    end
  end
  first = math.min(first, #words - 1)
  if first < 1 then
    soda.message("Nothing to transpose")
    return
  end
  local a, b = words[first], words[first + 1]
  buf:edit({
    { { line, a[1] }, { line, a[2] }, text:sub(b[1], b[2] - 1) },
    { { line, b[1] }, { line, b[2] }, text:sub(a[1], a[2] - 1) },
  })
  buf:set_selection({ line, b[2] })
end)

-- The run of spaces and tabs around a column, end excluded.
local function spaces(text, column)
  local from, to = column, column
  while from > 1 and text:sub(from - 1, from - 1):find("[ \t]") do
    from = from - 1
  end
  while to <= #text and text:sub(to, to):find("[ \t]") do
    to = to + 1
  end
  return from, to
end
local function replace_spaces(with)
  return function()
    local buf = soda.buffer()
    local line, column, text = caret(buf)
    local from, to = spaces(text, column)
    buf:edit({ { { line, from }, { line, to }, with } })
    buf:set_selection({ line, from + #with })
  end
end
soda.define_command("delete-horizontal-space", "Delete spaces and tabs around the caret", replace_spaces(""))
soda.define_command("just-one-space", "Leave one space around the caret", replace_spaces(" "))

soda.define_command("join-line", "Join this line to the previous one", function()
  local buf = soda.buffer()
  local line, _, text = caret(buf)
  if line == 1 then
    return
  end
  local previous = buf:line(line - 1)
  local kept = previous:match("^(.-)[ \t]*$")
  local start = text:find("%S") or #text + 1
  local joint = (kept == "" or start > #text) and "" or " "
  buf:edit({ { { line - 1, #kept + 1 }, { line, start }, joint } })
  buf:set_selection({ line - 1, #kept + 1 })
end)

soda.define_command("open-line", "Insert a newline after the caret", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  buf:edit({ { head, head, "\n" } })
  buf:set_selection(head)
end)

soda.define_command("back-to-indentation", "Go to the first non-blank of the line", function()
  local buf = soda.buffer()
  local line, _, text = caret(buf)
  buf:set_selection({ line, text:find("%S") or #text + 1 })
end)

for _, mode in ipairs({ "normal", "insert" }) do
  soda.map_default(mode, "<a-u>", "upcase-word")
  soda.map_default(mode, "<a-l>", "downcase-word")
  soda.map_default(mode, "<a-c>", "capitalize-word")
  soda.map_default(mode, "<a-t>", "transpose-words")
  soda.map_default(mode, "<c-t>", "transpose-chars")
  soda.map_default(mode, "<a-\\>", "delete-horizontal-space")
  soda.map_default(mode, "<a-space>", "just-one-space")
  soda.map_default(mode, "<a-^>", "join-line")
end
soda.map_default("insert", "<c-o>", "open-line")
soda.map_default("insert", "<a-m>", "back-to-indentation")
