-- What git says about a path, for other modules and init.lua; it only
-- looks, it changes nothing.
--
--   local git = require("git")
--   git.root("src/main.cpp")            --> "/home/me/project" or nil
--   git.status("src/main.cpp", function(status) ... end)
--
-- `root` looks for `.git` above the path, as `roots = { "git" }` of a
-- language server does: the top of the working tree, a submodule's or a
-- linked worktree's included. `status` runs git in the background and
-- calls back with nil outside a repository, or a table:
--
--   root, head (the commit, nil before the first), branch (nil when
--   detached), upstream, ahead, behind,
--   tracked, ignored, untracked, staged, modified, conflicted
--
-- The flags are about the path; for a directory, about any file in it.

local M = {}

local function absolute(path)
  if path:sub(1, 2) == "~/" then
    path = (os.getenv("HOME") or "") .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    path = soda.val("root") .. "/" .. path
  end
  path = path:gsub("/+$", "")
  return path == "" and "/" or path
end
local function directory_of(path)
  if soda.file_kind(path) == "directory" then
    return path
  end
  return path:match("^(.*)/[^/]*$") or "/"
end

function M.root(path)
  local dir = directory_of(absolute(path))
  while dir do
    if soda.file_kind((dir == "/" and "" or dir) .. "/.git") then
      return dir
    end
    if dir == "/" then
      return nil
    end
    dir = dir:match("^(.*)/[^/]*$")
    if dir == "" then
      dir = "/"
    end
  end
  return nil
end

-- `git status --porcelain=v2 -z` of one path.
local function parse(out, status)
  local fields = {}
  for field in out:gmatch("([^\0]*)\0") do
    table.insert(fields, field)
  end
  local index = 1
  while index <= #fields do
    local field = fields[index]
    local kind = field:sub(1, 1)
    if kind == "#" then
      local key, value = field:match("^# (%S+) (.*)$")
      if key == "branch.oid" and value ~= "(initial)" then
        status.head = value
      elseif key == "branch.head" and value ~= "(detached)" then
        status.branch = value
      elseif key == "branch.upstream" then
        status.upstream = value
      elseif key == "branch.ab" then
        local ahead, behind = value:match("^%+(%d+) %-(%d+)$")
        status.ahead, status.behind = tonumber(ahead), tonumber(behind)
      end
    elseif kind == "1" or kind == "2" or kind == "u" then
      local x, y = field:sub(3, 3), field:sub(4, 4)
      if kind == "u" then
        status.conflicted = true
      else
        status.staged = status.staged or x ~= "."
        status.modified = status.modified or y ~= "."
      end
      -- A rename names where it came from in the next field.
      if kind == "2" then
        index = index + 1
      end
    elseif kind == "?" then
      status.untracked = true
    elseif kind == "!" then
      status.ignored = true
    end
    index = index + 1
  end
end

function M.status(path, done)
  path = absolute(path)
  local dir = directory_of(path)
  soda.spawn({ "git", "rev-parse", "--show-toplevel" }, function(code, out)
    if code ~= 0 then
      done(nil)
      return
    end
    local root = out:gsub("%s+$", "")
    soda.spawn(
      { "git", "status", "--porcelain=v2", "--branch", "--ignored=matching", "-z", "--", path },
      function(code, out)
        if code ~= 0 then
          done(nil)
          return
        end
        local status = {
          root = root,
          staged = false,
          modified = false,
          untracked = false,
          ignored = false,
          conflicted = false,
        }
        parse(out, status)
        status.tracked = not status.untracked and not status.ignored
        done(status)
      end,
      { cwd = dir }
    )
  end, { cwd = dir })
end

return M
