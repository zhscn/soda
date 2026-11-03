-- Snippets as completion candidates, per language. None are built in: add
-- yours from init.lua, by a language's id, or "*" for every language:
--
--   require("snippets").add("cpp", {
--     fori = "for (int ${1:i} = 0; $1 < ${2:n}; ++$1) {\n\t$0\n}",
--     main = { body = "int main() {\n\t$0\n}", description = "The entry point" },
--   })
--
-- or load them from files in VSCode's format, one file or a directory of
-- them with a package.json, such as friendly-snippets:
--
--   require("snippets").load("~/.config/soda/snippets/cpp.json", "cpp")
--   require("snippets").load("~/src/friendly-snippets")
--
-- Typing a name lists its snippet; Tab takes it and goes through its places.

local M = {}
-- By language, then by name: { body, description }.
local snippets = {}

local function lines(value)
  if type(value) == "table" then
    return table.concat(value, "\n")
  end
  return value
end

function M.add(language, table_of_snippets)
  snippets[language] = snippets[language] or {}
  for name, snippet in pairs(table_of_snippets) do
    if type(snippet) == "string" then
      snippet = { body = snippet }
    end
    snippets[language][name] = { body = lines(snippet.body), description = snippet.description }
  end
end

local function expand(path)
  if path:sub(1, 2) == "~/" then
    return (os.getenv("HOME") or "") .. path:sub(2)
  end
  return path
end
local function read(path)
  local file, failure = io.open(path, "rb")
  if not file then
    error(failure, 0)
  end
  local text = file:read("a")
  file:close()
  return soda.json_decode(text)
end
-- VSCode's ids where soda's differ.
local aliases = { plaintext = "text" }
local function split(list)
  local languages = {}
  for language in list:gmatch("[^,%s]+") do
    table.insert(languages, language)
  end
  return languages
end

-- One file of VSCode snippets: each entry has a prefix (or several), a body
-- (a string or lines), and maybe a description and the languages it is for,
-- `scope`, which a language given here overrides.
local function load_file(path, language)
  local count = 0
  for name, entry in pairs(read(path)) do
    if type(entry) == "table" and entry.body then
      local prefixes = entry.prefix or name
      if type(prefixes) == "string" then
        prefixes = { prefixes }
      end
      local languages = language and { language }
        or (entry.scope and entry.scope ~= "" and split(entry.scope))
        or { "*" }
      local description = entry.description
      if type(description) == "table" then
        description = table.concat(description, "\n")
      end
      for _, each in ipairs(languages) do
        each = aliases[each] or each
        for _, prefix in ipairs(prefixes) do
          M.add(each, { [prefix] = { body = entry.body, description = description or name } })
          count = count + 1
        end
      end
    end
  end
  return count
end

-- Loads a file, for `language` or the scopes it names, or a directory whose
-- package.json lists its files under contributes.snippets. Returns how
-- many snippets it added.
function M.load(path, language)
  path = expand(path)
  if soda.file_kind(path) ~= "directory" then
    return load_file(path, language)
  end
  local package = read(path .. "/package.json")
  local count = 0
  for _, contribution in ipairs((package.contributes or {}).snippets or {}) do
    local file = path .. "/" .. (contribution.path:gsub("^%./", ""))
    local languages = contribution.language
    if type(languages) == "string" then
      languages = { languages }
    end
    for _, each in ipairs(languages or { language or "*" }) do
      if not language or (aliases[each] or each) == language then
        count = count + load_file(file, each)
      end
    end
  end
  return count
end

soda.completion.register({
  complete = function(context, sink)
    local items = {}
    for _, language in ipairs({ context.language, "*" }) do
      for name, snippet in pairs(snippets[language] or {}) do
        table.insert(items, { label = name, snippet = snippet.body, detail = "snippet", doc = snippet.description })
      end
    end
    if #items > 0 then
      sink:add(items)
    end
    sink:done()
  end,
})

return M
