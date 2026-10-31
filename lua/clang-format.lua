-- Formats the buffer with clang-format, or the lines of a Visual selection.
-- Only lines that change are replaced, so the caret stays where it was. If
-- the buffer changes while clang-format runs, the output is dropped.
-- Copy to ~/.config/soda/lua/ and add to init.lua:
--
--   require("clang-format")

local function lines(text)
  local list = {}
  for line in text:gmatch("[^\n]*\n?") do
    table.insert(list, line)
  end
  return list
end

-- The one replacement that turns old into new: the byte range of old it
-- covers, counted from 1, and the text that goes there.
local function difference(old, new)
  local before, after = lines(old), lines(new)
  local first, start = 1, 1
  while first <= #before and first <= #after and before[first] == after[first] do
    start = start + #before[first]
    first = first + 1
  end
  local last_old, last_new, stop = #before, #after, #old + 1
  while last_old >= first and last_new >= first and before[last_old] == after[last_new] do
    stop = stop - #before[last_old]
    last_old, last_new = last_old - 1, last_new - 1
  end
  return start, stop, table.concat(after, "", first, last_new)
end

soda.define_command("clang-format", function()
  local buf = soda.buffer()
  local text, revision = buf:text(), buf:revision()
  local file = soda.val("file")
  local argv = { "clang-format", "--assume-filename=" .. (file ~= "" and file or "soda.cpp") }
  local mode = soda.val("mode")
  if mode == "visual" or mode == "visual-line" then
    local anchor, head = buf:selection()
    local from, to = math.min(anchor[1], head[1]), math.max(anchor[1], head[1])
    -- The range leaves out its end: at a line's start, that line is not selected.
    local last = anchor[1] > head[1] and anchor or head
    if last[2] == 1 and to > from then
      to = to - 1
    end
    table.insert(argv, "--lines=" .. from .. ":" .. to)
  end
  soda.spawn(argv, function(code, out, err)
    if code ~= 0 then
      soda.message("clang-format: " .. (err:match("[^\n]+") or "failed"))
      return
    end
    if buf:revision() ~= revision then
      soda.message("clang-format: buffer changed while it ran; output dropped")
      return
    end
    if out == text then
      return
    end
    local start, stop, replacement = difference(text, out)
    buf:edit({ { buf:point(start), buf:point(stop), replacement } }, revision)
  end, text)
end)
