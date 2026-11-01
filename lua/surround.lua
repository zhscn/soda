-- Puts a pair around the Visual selection: `surround (`, `surround "`, or
-- two words for any pair, as in `surround <b> </b>`. An opening bracket
-- brings its closing one; any other single argument goes on both sides.
-- Built in: S followed by a bracket or quote in Visual.

local closing = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }

soda.define_command("surround", function(argument)
  local open, close = argument:match("^(%S+)%s+(%S+)$")
  if not open then
    open = argument:match("^%S+$")
    close = open and (closing[open] or open)
  end
  if not open then
    soda.message("surround: give a pair, as in surround (")
    return
  end
  local mode = soda.val("mode")
  if mode ~= "visual" and mode ~= "visual-line" then
    soda.message("surround: select text first")
    return
  end
  local buf = soda.buffer()
  local from, to = buf:selection()
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  buf:edit({ { from, from, open }, { to, to, close } })
end)

for _, key in ipairs({ "(", "[", "{", '"', "'", "`" }) do
  soda.command("map visual S" .. key .. " surround " .. key)
end
