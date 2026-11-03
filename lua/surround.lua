-- Puts a pair around the selection: `surround (`, `surround "`, or
-- two words for any pair, as in `surround <b> </b>`. An opening bracket
-- brings its closing one; any other single argument goes on both sides.
-- The command is there without setup. setup binds C-c (SPC in Normal)
-- followed by a bracket or quote; `keys = false` binds none.
--
--   require("surround").setup()

local closing = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }

soda.define_command("surround", "Put a pair around the selection", function(argument)
  local open, close = argument:match("^(%S+)%s+(%S+)$")
  if not open then
    open = argument:match("^%S+$")
    close = open and (closing[open] or open)
  end
  if not open then
    soda.message("surround: give a pair, as in surround (")
    return
  end
  local buf = soda.buffer()
  local from, to = buf:selection()
  if from[1] == to[1] and from[2] == to[2] then
    soda.message("surround: select text first")
    return
  end
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  buf:edit({ { from, from, open }, { to, to, close } })
end)

local M = {}

function M.setup(options)
  options = options or {}
  if options.keys == false then
    return
  end
  for _, key in ipairs({ "(", "[", "{", '"', "'", "`" }) do
    soda.map_default("global", "C-c " .. key, "surround " .. key)
  end
end

return M
