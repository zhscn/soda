-- Interactive ripgrep: choose a query, file type or glob, and directory.
-- Search state stays available for rerunning and refining from *rg*.
local M = {}
local last, types
local defaults = { case = "smart", literal = false, hidden = false, no_ignore = false }

local function copy(value)
  local result = {}
  for key, item in pairs(value) do result[key] = item end
  return result
end
local function absolute(path, base)
  if path == "~" then return os.getenv("HOME") or path end
  if path:sub(1, 2) == "~/" then return (os.getenv("HOME") or "~") .. path:sub(2) end
  if path:sub(1, 1) == "/" then return path end
  return base .. "/" .. path
end
local function word()
  local ok, value = pcall(soda.val, "word")
  return ok and value or ""
end
local function current_directory()
  local file = soda.val("file")
  return file:match("^(.*)/[^/]*$") or soda.val("root")
end
local function suggested_type()
  if soda.val("file"):match("%.c$") then return "c" end
  local language = soda.buffer():language()
  return ({ text = "everything", makefile = "make", shellscript = "sh" })[language] or language
end
local function start(spec)
  if spec.pattern == "" then
    soda.message("rg: enter a search pattern")
    return
  end
  if soda.file_kind(spec.directory) ~= "directory" then
    soda.message("rg: not a directory: " .. spec.directory)
    return
  end
  last = copy(spec)
  local insensitive = soda.ripgrep(spec)
  last.case = insensitive and "insensitive" or "sensitive"
end

local function file_choices(spec, suggested, done)
  local function choose()
    local items = {}
    local function add(name, doc) table.insert(items, { name, doc }) end
    -- Completing-read's first candidate supplies the context-sensitive
    -- default; choosing custom opens a field that accepts any glob.
    local custom = suggested:match("^glob:(.*)$")
    if custom then add("custom", custom) end
    if suggested == "everything" or suggested == "all" or types[suggested] then
      add(suggested, types[suggested] or "Suggested scope")
    end
    if suggested ~= "everything" then add("everything", "All files, subject to ignore rules") end
    if suggested ~= "all" then add("all", "All file types known to ripgrep") end
    if not custom then add("custom", "Enter a file glob, for example *.{c,h}") end
    local names = {}
    for name in pairs(types) do if name ~= suggested then table.insert(names, name) end end
    table.sort(names)
    for _, name in ipairs(names) do add(name, types[name]) end
    soda.choose("rg files", items, function(files)
      if files == "custom" then
        local initial = spec.files and spec.files:match("^glob:(.*)$") or "*"
        soda.input("rg glob", initial, function(glob)
          if glob == "" then soda.message("rg: enter a file glob"); return end
          spec.files = "glob:" .. glob
          done()
        end, "rg-glob")
      else
        spec.files = files
        done()
      end
    end, "rg-files")
  end
  if types then choose(); return end
  soda.spawn({ "rg", "--no-config", "--type-list" }, function(code, out, err)
    if code ~= 0 then soda.message("rg: " .. (err:match("[^\n]+") or "cannot list file types")); return end
    types = {}
    for name, globs in out:gmatch("([^\n:]+): ([^\n]+)") do types[name] = globs end
    choose()
  end)
end
local function ask_directory(spec, done)
  local base = soda.val("root")
  soda.choose("rg directory", "path", function(directory)
    spec.directory = absolute(directory, base)
    done()
  end, "rg-directory", spec.directory:gsub("/+$", "") .. "/")
end
local function search(query, literal, project)
  local spec = copy(defaults)
  spec.literal = literal
  spec.directory = project and soda.val("root") or current_directory()
  local suggested = suggested_type()
  local function files()
    file_choices(spec, suggested, function()
      if project then start(spec) else ask_directory(spec, function() start(spec) end) end
    end)
  end
  if query and query ~= "" then spec.pattern = query; files(); return end
  soda.input(literal and "rg literal" or "rg regexp", word(), function(pattern)
    spec.pattern = pattern
    files()
  end, "rg-query")
end
local function previous()
  if not last then soda.message("rg: no previous search"); return end
  return copy(last)
end

soda.define_command("rg", "Search with ripgrep: choose a regexp, files and directory", function(query)
  search(query, false, false)
end, { args = { { name = "PATTERN", kind = "rest", optional = true } } })
soda.define_command("rg-literal", "Search literal text with ripgrep", function(query)
  search(query, true, false)
end, { args = { { name = "TEXT", kind = "rest", optional = true } } })
soda.define_command("rg-project", "Search with ripgrep in the current project", function(query)
  search(query, false, true)
end, { args = { { name = "PATTERN", kind = "rest", optional = true } } })
soda.define_command("rg-dwim", "Search the word at point in the project, using the current file type", function()
  local spec = copy(defaults)
  spec.pattern, spec.directory = word(), soda.val("root")
  spec.files = suggested_type()
  start(spec)
end)
soda.define_command("rg-rerun", "Run the previous ripgrep search again", function()
  local spec = previous()
  if spec then start(spec) end
end)
soda.define_command("rg-rerun-change-regexp", "Change the previous ripgrep query and search again", function()
  local spec = previous()
  if not spec then return end
  soda.input(spec.literal and "rg literal" or "rg regexp", spec.pattern, function(pattern)
    spec.pattern = pattern
    start(spec)
  end, "rg-query")
end)
soda.define_command("rg-rerun-change-files", "Change the previous ripgrep file filter and search again", function()
  local spec = previous()
  if spec then file_choices(spec, spec.files, function() start(spec) end) end
end)
soda.define_command("rg-rerun-change-dir", "Change the previous ripgrep directory and search again", function()
  local spec = previous()
  if spec then ask_directory(spec, function() start(spec) end) end
end)
soda.define_command("rg-rerun-toggle-case", "Toggle case sensitivity and repeat the ripgrep search", function()
  local spec = previous()
  if not spec then return end
  local insensitive = spec.case == "insensitive"
  spec.case = insensitive and "sensitive" or "insensitive"
  start(spec)
end)
for _, toggle in ipairs({
  { "literal", "literal", "literal matching" },
  { "ignore", "no_ignore", "ignore rules" },
  { "hidden", "hidden", "hidden files" },
}) do
  soda.define_command("rg-rerun-toggle-" .. toggle[1], "Toggle " .. toggle[3] .. " and repeat the ripgrep search", function()
    local spec = previous()
    if spec then spec[toggle[2]] = not spec[toggle[2]]; start(spec) end
  end)
end
soda.define_command("rg-menu", "Choose a ripgrep search or refine the previous search", function()
  local items = {
    { "rg", "New regexp search" }, { "rg-literal", "New literal search" },
    { "rg-project", "Search the project" }, { "rg-dwim", "Search the word at point" },
    { "case", "New searches: case=" .. defaults.case },
    { "hidden", "New searches: hidden=" .. tostring(defaults.hidden) },
    { "no_ignore", "New searches: no-ignore=" .. tostring(defaults.no_ignore) },
  }
  if last then
    for _, item in ipairs({
      { "rg-rerun", "Repeat search" }, { "rg-rerun-change-regexp", "Change query" },
      { "rg-rerun-change-files", "Change files" }, { "rg-rerun-change-dir", "Change directory" },
      { "rg-rerun-toggle-case", "Toggle case (" .. last.case .. ")" },
      { "rg-rerun-toggle-literal", "Toggle literal (" .. tostring(last.literal) .. ")" },
      { "rg-rerun-toggle-ignore", "Toggle no-ignore (" .. tostring(last.no_ignore) .. ")" },
      { "rg-rerun-toggle-hidden", "Toggle hidden (" .. tostring(last.hidden) .. ")" },
    }) do table.insert(items, item) end
  end
  soda.choose("rg", items, function(command)
    if command == "case" then
      soda.choose("rg case", { "smart", "sensitive", "insensitive" }, function(value)
        defaults.case = value
        soda.command("rg-menu")
      end)
    elseif command == "hidden" or command == "no_ignore" then
      defaults[command] = not defaults[command]
      soda.command("rg-menu")
    else
      soda.command(command)
    end
  end)
end)

function M.search(spec)
  local options = copy(defaults)
  for key, value in pairs(spec) do options[key] = value end
  options.files = options.files or "everything"
  options.directory = absolute(options.directory or soda.val("root"), soda.val("root"))
  start(options)
end
return M
