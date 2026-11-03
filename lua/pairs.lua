-- Structural editing, as puni does it in Emacs: moving over and killing
-- whole expressions, deleting without breaking pairs, and moving a closing
-- bracket over its neighbours. All of it rests on three questions a buffer
-- answers for any language: buf:enclosing, buf:next_item, buf:prev_item.
-- Where they have no answer, as with an unfinished expression, the commands
-- do what the built-in ones do.
--
-- Built in, with Emacs's own keys, in Insert and Normal: C-M-f C-M-b
-- C-M-u move, C-M-SPC selects the expression, C-M-k and C-M-DEL kill
-- one. The rest, puni's keys among them, come with the puni
-- plugin: require("puni").setup().

local function before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end
local function same(a, b)
  return a[1] == b[1] and a[2] == b[2]
end
local function line_end(buf, line)
  return { line, #buf:line(line) + 1 }
end
local function selecting(buf)
  local anchor, head = buf:selection()
  return not same(anchor, head)
end

-- The nearest expression, past comments and directives.
local function step(buf, at, method)
  local item = buf[method](buf, at)
  while item and (item.kind == "comment" or item.kind == "directive") do
    at = method == "next_item" and item.to or item.from
    item = buf[method](buf, at)
  end
  return item
end

local function move(buf, to)
  if selecting(buf) then
    local anchor = buf:selection()
    buf:select(anchor, to)
  else
    buf:set_selection(to)
  end
end

soda.define_command("sexp-forward", "Go past the next expression", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "next_item")
  if item then
    move(buf, item.to)
  end
end)
soda.define_command("sexp-backward", "Go back over the previous expression", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "prev_item")
  if item then
    move(buf, item.from)
  end
end)
soda.define_command("sexp-up", "Go to the start of the enclosing group", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  if group then
    move(buf, group.from)
  end
end)

-- Selects the group at the caret, then the group around the selection.
soda.define_command("sexp-expand", "Select the group at the caret, then the one around it", function()
  local buf = soda.buffer()
  local anchor, head = buf:selection()
  local from, to = anchor, head
  if before(to, from) then
    from, to = to, from
  end
  local range
  if selecting(buf) then
    range = buf:enclosing(from)
    while range and before(range.to, to) do
      range = buf:enclosing(range.from)
    end
    if range and same(range.from, from) and same(range.to, to) then
      range = buf:enclosing(range.from)
    end
  else
    local item = buf:next_item(head)
    if item and item.kind == "group" and same(item.from, head) then
      range = item
    else
      range = buf:enclosing(head)
    end
  end
  if range then
    buf:select(range.from, range.to)
  end
end)

-- Where a kill from `at` stops: the end of the line, or past an expression
-- that goes on beyond it, or before the bracket that closes the group.
local function kill_end(buf, at)
  local stop = line_end(buf, at[1])
  local position = at
  while true do
    local item = buf:next_item(position)
    if not item then
      local group = buf:enclosing(at)
      if group and before(group.inner_to, stop) then
        return group.inner_to
      end
      return stop
    end
    if not before(item.from, stop) then
      return stop
    end
    if before(stop, item.to) then
      return item.to
    end
    position = item.to
  end
end

soda.define_command("sexp-kill", "Kill to the line end, keeping pairs whole", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  if same(head, line_end(buf, head[1])) or buf:in_literal(head) then
    soda.command("kill-line-end")
    return
  end
  local stop = kill_end(buf, head)
  if not same(stop, head) then
    buf:kill(head, stop)
  end
end)

local closers = { [")"] = true, ["]"] = true, ["}"] = true }
local openers = { ["("] = true, ["["] = true, ["{"] = true }
local quotes = { ['"'] = true, ["'"] = true }

local function backspace()
  soda.command("delete-backward")
end

local function soft_backspace(buf)
  local anchor, head = buf:selection()
  if not same(anchor, head) or head[2] == 1 then
    return backspace()
  end
  local left = { head[1], head[2] - 1 }
  local char = buf:line(head[1]):sub(left[2], left[2])
  if not (closers[char] or openers[char] or quotes[char]) then
    return backspace()
  end
  if quotes[char] then
    local item = buf:prev_item(head)
    if not item or item.kind ~= "literal" then
      return backspace()
    end
    local following = buf:line(head[1]):sub(head[2], head[2])
    if same(item.from, left) and following ~= char then
      -- After an opening quote: the text stays a literal.
      buf:set_selection(left)
    elseif same(item.to, head) and not buf:in_literal(head) then
      local empty = item.to[1] == item.from[1] and item.to[2] - item.from[2] == 2
      if empty then
        buf:edit({ { item.from, item.to, "" } })
      else
        buf:set_selection(left)
      end
    else
      return backspace()
    end
    return
  end
  if buf:in_literal(head) then
    return backspace()
  end
  if closers[char] then
    local item = buf:prev_item(head)
    if item and item.kind == "group" and same(item.to, head) then
      buf:set_selection(left)
    else
      backspace()
    end
    return
  end
  local group = buf:enclosing(head)
  if not group or not same(group.from, left) then
    return backspace()
  end
  if same(group.inner_from, group.inner_to) then
    buf:edit({ { group.from, group.to, "" } })
  else
    buf:set_selection(left)
  end
end

soda.define_command("soft-backspace", "Delete backward without breaking a pair", function()
  soft_backspace(soda.buffer())
end)

-- A word goes as usual, into the kill ring; punctuation goes up to the
-- nearest bracket, and at a bracket deletion is a soft backspace. The
-- selection plays no part, as in puni's `puni-backward-kill-word`.
local function soft_kill_word(buf)
  local _, head = buf:selection()
  local before_caret = buf:line(head[1]):sub(1, head[2] - 1)
  local run = before_caret:match("[^%w_%s]+%s*$")
  if not run or not run:find("[%(%)%[%]{}\"']") or buf:in_literal(head) then
    soda.command("kill-word-backward")
    return
  end
  local tail = run:match("[^%(%)%[%]{}\"']*$")
  if tail == "" then
    soft_backspace(buf)
  else
    buf:kill({ head[1], head[2] - #tail }, head)
  end
end
soda.define_command("soft-kill-word", "Cut a word backward without breaking a pair", function()
  soft_kill_word(soda.buffer())
end)
-- `C-w` as `puni-kill-region`: the selection, or else a word backward.
soda.define_command("kill-region-or-word", "Cut the selection, or else a word backward", function()
  local buf = soda.buffer()
  local anchor, head = buf:selection()
  if same(anchor, head) then
    soft_kill_word(buf)
  else
    soda.command("cut")
  end
end)

-- Moves the closing bracket past the next expression.
soda.define_command("sexp-slurp", "Move the closing bracket past the next expression", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  local item = group and step(buf, group.to, "next_item")
  if not item then
    soda.message("Nothing to slurp")
    return
  end
  local close = buf:text(group.inner_to, group.to)
  buf:edit({ { group.inner_to, group.to, "" }, { item.to, item.to, close } })
end)
-- Moves the closing bracket before the last expression inside.
soda.define_command("sexp-barf", "Move the closing bracket before the last expression", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  local last = group and step(buf, group.inner_to, "prev_item")
  if not last then
    soda.message("Nothing to barf")
    return
  end
  local previous = step(buf, last.from, "prev_item")
  local target = previous and previous.to or group.inner_from
  local close = buf:text(group.inner_to, group.to)
  buf:edit({ { target, target, close }, { group.inner_to, group.to, "" } })
end)

soda.define_command("sexp-beginning", "Go to the start of the group's contents", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  if group then
    move(buf, group.inner_from)
  end
end)

soda.define_command("sexp-end", "Go to the end of the group's contents", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  if group then
    move(buf, group.inner_to)
  end
end)

soda.define_command("sexp-kill-forward", "Kill the next expression", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "next_item")
  if item then
    buf:kill(head, item.to)
  end
end)

soda.define_command("sexp-kill-backward", "Kill the previous expression", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "prev_item")
  if item then
    buf:kill(item.from, head)
  end
end)

for _, mode in ipairs({ "normal", "insert" }) do
  soda.map_default(mode, "C-M-f", "sexp-forward")
  soda.map_default(mode, "C-M-b", "sexp-backward")
  soda.map_default(mode, "C-M-u", "sexp-up")
  soda.map_default(mode, "C-M-SPC", "sexp-expand")
  soda.map_default(mode, "C-M-k", "sexp-kill-forward")
  soda.map_default(mode, "C-M-DEL", "sexp-kill-backward")
end
