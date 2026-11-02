-- Flags lines that differ from what git has staged: + for added lines,
-- ~ for changed ones and _ under the place where lines were removed.
-- Not started by default; add to init.lua:
--
--   require("git-flags")

local function hunks(diff)
  local added, changed, removed = {}, {}, {}
  for old, start, count in diff:gmatch("\n@@ %-%d+,?(%d*) %+(%d+),?(%d*) @@") do
    old = old == "" and 1 or tonumber(old)
    start = tonumber(start)
    count = count == "" and 1 or tonumber(count)
    if count == 0 then
      table.insert(removed, math.max(start, 1))
    else
      local into = old == 0 and added or changed
      for line = start, start + count - 1 do
        table.insert(into, line)
      end
    end
  end
  return added, changed, removed
end

local function update(path)
  if path == "" then
    return
  end
  soda.spawn({ "git", "diff", "--no-color", "--no-ext-diff", "-U0", "--", path }, function(code, out)
    soda.unflag("git")
    if code ~= 0 then
      return
    end
    local added, changed, removed = hunks("\n" .. out)
    if #removed > 0 then soda.flag("git", "error", "_", removed) end
    if #changed > 0 then soda.flag("git", "mark3", "~", changed) end
    if #added > 0 then soda.flag("git", "mark2", "+", added) end
  end)
end

soda.hook("open", ".*", update)
soda.hook("save", ".*", update)
soda.define_command("git-flags", "Refresh the git flags of the buffer", function() update(soda.val("file")) end)
