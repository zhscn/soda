-- Lists the places that differ from what git has staged in *changes*, one
-- per hunk, for Enter, ]q and [q. `git diff` output has no `path:line:` of
-- its own, so this turns its hunk headers into locations.
-- Built in: SPC g.

soda.command("display changes bottom")
soda.command("map global <c-c>g git-changes")

local function locations(diff)
  local list, path = {}, nil
  local added, entry = 0, nil
  for line in diff:gmatch("[^\n]*") do
    local file = added == 0 and line:match("^%+%+%+ b/(.+)$")
    local start, count = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    if file then
      path = file
    elseif start then
      added = count == "" and 1 or tonumber(count)
      entry = path .. ":" .. math.max(tonumber(start), 1) .. ":"
      if added == 0 then
        table.insert(list, entry .. " (lines removed)")
      end
    elseif added > 0 and line:sub(1, 1) == "+" then
      if entry then
        table.insert(list, entry .. " " .. line:sub(2))
        entry = nil
      end
      added = added - 1
    end
  end
  return list
end

soda.define_command("git-changes", function()
  local argv = {
    "git", "diff", "-U0", "--relative", "--no-color", "--no-ext-diff",
    "--src-prefix=a/", "--dst-prefix=b/",
  }
  soda.spawn(argv, function(code, out, err)
    if code ~= 0 then
      soda.message("git-changes: " .. (err:match("[^\n]+") or "failed"))
      return
    end
    soda.results("changes", locations(out))
  end)
end)
