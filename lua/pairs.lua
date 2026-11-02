-- Structural editing, as puni does it in Emacs: moving over and killing
-- whole expressions, deleting without breaking pairs, and moving a closing
-- bracket over its neighbours. All of it rests on three questions a buffer
-- answers for any language: buf:enclosing, buf:next_item, buf:prev_item.
-- Where they have no answer, as with an unfinished expression, the commands
-- do what the built-in ones do.
--
-- Built in, with Emacs's keys: <c-a-f> <c-a-b> <c-a-u> <c-a-a> <c-a-e> move
-- in every mode; <a-o> and <c-a-space> select in Normal; <c-k>,
-- <c-a-k>, <c-a-bs>, <c-s-right> and <c-s-left> work in Normal and Insert;
-- Backspace and word deletion are soft in Insert. To keep a built-in key,
-- unmap it:
--
--   soda.command("unmap insert <bs>")

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

soda.define_command("sexp-forward", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "next_item")
  if item then
    move(buf, item.to)
  end
end)
soda.define_command("sexp-backward", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "prev_item")
  if item then
    move(buf, item.from)
  end
end)
soda.define_command("sexp-up", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  if group then
    move(buf, group.from)
  end
end)

-- Selects the group at the caret, then the group around the selection.
soda.define_command("sexp-expand", function()
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

soda.define_command("sexp-kill", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  if same(head, line_end(buf, head[1])) or buf:in_literal(head) then
    soda.command("kill-line-end")
    return
  end
  local stop = kill_end(buf, head)
  if not same(stop, head) then
    soda.clipboard(buf:text(head, stop))
    buf:edit({ { head, stop, "" } })
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

soda.define_command("soft-backspace", function()
  soft_backspace(soda.buffer())
end)

-- A word goes as usual; punctuation goes up to the nearest bracket, and at
-- a bracket deletion is a soft backspace.
soda.define_command("soft-delete-word", function()
  local buf = soda.buffer()
  local anchor, head = buf:selection()
  local before_caret = buf:line(head[1]):sub(1, head[2] - 1)
  local run = before_caret:match("[^%w_%s]+%s*$")
  if not same(anchor, head) or not run or not run:find("[%(%)%[%]{}\"']") or buf:in_literal(head) then
    soda.command("delete-word-backward")
    return
  end
  local tail = run:match("[^%(%)%[%]{}\"']*$")
  if tail == "" then
    soft_backspace(buf)
  else
    buf:edit({ { { head[1], head[2] - #tail }, head, "" } })
  end
end)

-- Moves the closing bracket past the next expression.
soda.define_command("sexp-slurp", function()
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
soda.define_command("sexp-barf", function()
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

local function kill_to(buf, from, to)
  soda.clipboard(buf:text(from, to))
  buf:edit({ { from, to, "" } })
end

soda.define_command("sexp-beginning", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  if group then
    move(buf, group.inner_from)
  end
end)

soda.define_command("sexp-end", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local group = buf:enclosing(head)
  if group then
    move(buf, group.inner_to)
  end
end)

soda.define_command("sexp-kill-forward", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "next_item")
  if item then
    kill_to(buf, head, item.to)
  end
end)

soda.define_command("sexp-kill-backward", function()
  local buf = soda.buffer()
  local _, head = buf:selection()
  local item = step(buf, head, "prev_item")
  if item then
    kill_to(buf, item.from, head)
  end
end)

for _, mode in ipairs({ "normal", "insert" }) do
  soda.command("map " .. mode .. " <c-a-f> sexp-forward")
  soda.command("map " .. mode .. " <c-a-b> sexp-backward")
  soda.command("map " .. mode .. " <c-a-u> sexp-up")
  soda.command("map " .. mode .. " <c-a-a> sexp-beginning")
  soda.command("map " .. mode .. " <c-a-e> sexp-end")
end
for _, mode in ipairs({ "normal" }) do
  soda.command("map " .. mode .. " <a-o> sexp-expand")
  soda.command("map " .. mode .. " <c-a-space> sexp-expand")
end
for _, mode in ipairs({ "normal", "insert" }) do
  soda.command("map " .. mode .. " <c-k> sexp-kill")
  soda.command("map " .. mode .. " <c-a-k> sexp-kill-forward")
  soda.command("map " .. mode .. " <c-a-bs> sexp-kill-backward")
  soda.command("map " .. mode .. " <c-s-right> sexp-slurp")
  soda.command("map " .. mode .. " <c-s-left> sexp-barf")
end
soda.command("map insert <bs> soft-backspace")
soda.command("map insert <c-h> soft-backspace")
soda.command("map insert <c-w> soft-delete-word")
soda.command("map insert <c-bs> soft-delete-word")
soda.command("map insert <a-bs> soft-delete-word")
