-- Toggles line comments on the caret's line, or on the lines of a Visual
-- selection: if every line with text is a comment they stop being comments,
-- otherwise all become comments at the shallowest indentation among them.
-- Built in: gc in Normal and Visual, <a-;> in those and Insert.

local function selected_lines(buf)
  local anchor, head = buf:selection()
  local mode = soda.val("mode")
  if mode ~= "visual" and mode ~= "visual-line" then
    return head[1], head[1]
  end
  local from, to = anchor, head
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  -- The range leaves out its end: at a line's start, that line is not selected.
  if to[2] == 1 and to[1] > from[1] then
    return from[1], to[1] - 1
  end
  return from[1], to[1]
end

soda.define_command("comment", function()
  local buf = soda.buffer()
  local marker = buf:line_comment()
  if not marker then
    soda.message("comment: no line comments in this language")
    return
  end
  local from, to = selected_lines(buf)
  local lines, indent, commented = {}, math.huge, true
  for number = from, to do
    local text = buf:line(number)
    local column = text:find("%S")
    if column then
      table.insert(lines, { number = number, text = text, column = column })
      indent = math.min(indent, column)
      commented = commented and text:sub(column, column + #marker - 1) == marker
    end
  end
  local changes = {}
  for _, line in ipairs(lines) do
    if commented then
      local stop = line.column + #marker
      if line.text:sub(stop, stop) == " " then
        stop = stop + 1
      end
      table.insert(changes, { { line.number, line.column }, { line.number, stop }, "" })
    else
      local at = { line.number, indent }
      table.insert(changes, { at, at, marker .. " " })
    end
  end
  buf:edit(changes)
end)

soda.command("map normal gc comment")
soda.command("map visual gc comment")
for _, mode in ipairs({ "normal", "visual", "insert" }) do
  soda.command("map " .. mode .. " <a-;> comment")
end
