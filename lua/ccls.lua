-- ccls for C and C++, with its extensions: hierarchies that open level
-- by level, members, variables of a type, moves by the syntax tree, and the
-- preprocessor branches it skips shown dim. In init.lua:
--
--   require("ccls").setup({
--     init = { cache = { directory = "/tmp/ccls" } },
--   })
--
-- Options: `command` (default { "ccls" }, which may be a wrapper),
-- `init` (initializationOptions),
-- `settings`, `roots` (default .ccls-root, .ccls, compile_commands.json),
-- `auto` (default "marked": only where one of the roots is; lsp-start
-- starts it anywhere),
-- and `languages` (default { "cpp" }).
--
-- The commands are there without setup: ccls-callers and ccls-callees
-- open the callers and the callees as trees, ccls-base and ccls-derived
-- the bases and the derived types, ccls-members the members. They have no
-- keys; bind them in the `ccls` keymap, which setup defines and which
-- holds in documents ccls serves, over the `lsp` one:
--
--   soda.map("ccls", "C-c v c", "ccls-callers")

local lsp = require("lsp")

local M = {}

local function encoding(buf)
  local info = soda.lsp.info(buf)
  return info and info.encoding or "utf-16"
end

-- Preprocessor branches that are not compiled, by URI, shown dim.
local skipped = {}
local function paint_skipped()
  local uri = soda.lsp.uri()
  if not uri then
    return
  end
  local buf = soda.buffer()
  local count = buf:line_count()
  local spans = {}
  for _, range in ipairs(skipped[uri] or {}) do
    local first, last = range.start.line + 1, range["end"].line + 1
    if first <= count then
      last = math.min(last, count)
      local column = lsp.to_byte(buf:line(last), range["end"].character, encoding()) + 1
      table.insert(spans, { from = { first, 1 }, to = { last, column }, face = "dim" })
    end
  end
  soda.paint("ccls-skipped", spans)
end

-- A node of ccls's hierarchies as a tree node: its name and where it is.
local function node_of(item, field)
  local place = ""
  if item.location then
    local entry = lsp.location_entry(item.location)
    place = lsp.relative(entry.path) .. ":" .. (entry.line + 1)
  end
  local children = nil
  if item.children and #item.children > 0 then
    children = {}
    for _, child in ipairs(item.children) do
      table.insert(children, node_of(child, field))
    end
  end
  local label = (field and item[field] ~= nil and item[field] ~= "") and item[field] or item.name
  return {
    -- A member's name comes after its offset, padded to line up.
    label = tostring(label or ""):gsub("^%s+", ""),
    detail = place,
    children = children,
    expanded = children ~= nil,
    leaf = (item.numChildren or 0) == 0,
    item = item,
  }
end

-- Asks for a hierarchy at the caret and shows it as a tree whose nodes
-- open by asking again, a level at a time. `extra` goes with every
-- request; `more(item)` adds what asking about a node needs.
local function hierarchy(name, method, extra, field, more)
  local params = lsp.here()
  if not params then
    soda.message("No language server for this document")
    return
  end
  -- The tree's document has no server; its nodes ask the source's.
  local origin = soda.buffer()
  local function with(base)
    for key, value in pairs(extra) do
      base[key] = value
    end
    base.levels, base.hierarchy = 1, true
    return base
  end
  lsp.send(name, method, with(params), function(root, failure)
    if failure then
      soda.message(lsp.failed(method, failure))
      return
    end
    if type(root) ~= "table" or root.id == nil then
      soda.message("Nothing here for " .. name)
      return
    end
    soda.tree({
      name = name,
      roots = { node_of(root, field) },
      expand = function(node, add)
        local ask = with({ id = node.item.id })
        for key, value in pairs(more and more(node.item) or {}) do
          ask[key] = value
        end
        local asked = lsp.send(name .. " " .. tostring(node.item.id), method, ask, function(result)
          local children = {}
          for _, child in ipairs(result and result.children or {}) do
            table.insert(children, node_of(child, field))
          end
          add(children)
        end, origin)
        if not asked then
          soda.message("The language server is gone")
          add({})
        end
      end,
      open = function(node)
        if node.item.location then
          lsp.open_location(node.item.location, origin)
        end
      end,
    })
  end)
end

soda.define_command("ccls-callers", "Show the callers as a tree", function()
  hierarchy("callers", "$ccls/call", { callee = false, callType = 3 })
end)
soda.define_command("ccls-callees", "Show the callees as a tree", function()
  hierarchy("callees", "$ccls/call", { callee = true, callType = 3 })
end)
local function inheritance(name, derived)
  hierarchy(name, "$ccls/inheritance", { derived = derived }, nil, function(item)
    return { kind = item.kind }
  end)
end
soda.define_command("ccls-base", "Show the base classes as a tree", function()
  inheritance("bases", false)
end)
soda.define_command("ccls-derived", "Show the derived classes as a tree", function()
  inheritance("derived", true)
end)
-- ccls's kinds of symbols: types 2, functions 3, variables 4.
local member_kinds = { variables = 4, functions = 3, types = 2 }
soda.define_command("ccls-members", "Show the members of the type as a tree", function(what)
  what = (what or ""):match("^%s*(.-)%s*$")
  local kind = member_kinds[what ~= "" and what or "variables"]
  if not kind then
    soda.message("ccls-members: variables, functions or types")
    return
  end
  hierarchy("members", "$ccls/member", { kind = kind, qualified = false }, "fieldName")
end, {
  args = {
    {
      name = "KIND",
      optional = true,
      choices = {
        { "variables", "Member variables" },
        { "functions", "Member functions" },
        { "types", "Nested types" },
      },
    },
  },
})

soda.define_command("ccls-vars", "List the variables of the type at the caret", function()
  local params = lsp.here()
  if not params then
    soda.message("No language server for this document")
    return
  end
  lsp.send("vars", "$ccls/vars", params, function(result, failure)
    if failure then
      soda.message(lsp.failed("$ccls/vars", failure))
      return
    end
    local entries = {}
    for _, location in ipairs(result or {}) do
      table.insert(entries, lsp.location_entry(location))
    end
    if #entries == 0 then
      soda.message("No variables of this type")
    else
      lsp.show("variables", entries)
    end
  end)
end)

-- Moves by the syntax tree: up to the enclosing declaration, down into the
-- first, left and right to its siblings.
local directions = { up = "U", down = "D", left = "L", right = "R" }
soda.define_command("ccls-navigate", "Move by the syntax tree", function(direction)
  direction = (direction or ""):match("^%s*(.-)%s*$")
  local letter = directions[direction]
  if not letter then
    soda.message("ccls-navigate: up, down, left or right")
    return
  end
  local params = lsp.here()
  if not params then
    soda.message("No language server for this document")
    return
  end
  params.direction = letter
  lsp.send("navigate", "$ccls/navigate", params, function(result, failure)
    if failure then
      soda.message(lsp.failed("$ccls/navigate", failure))
    elseif result and result[1] then
      lsp.open_location(result[1])
    else
      soda.message("Nothing " .. direction)
    end
  end)
end, {
  args = { { name = "DIRECTION", choices = { "up", "down", "left", "right" } } },
})

soda.define_command("ccls-reload", "Make ccls index the project again", function()
  if not soda.lsp.notify("$ccls/reload", {}) then
    soda.message("No language server for this document")
  end
end)

-- Runs ccls for C++.
local started = false
function M.setup(options)
  options = options or {}
  if not started then
    started = true
    -- After `lsp`'s, so that it is asked first where both hold.
    soda.keymap("ccls", { server = "ccls", doc = "Documents ccls serves" })
    soda.lsp.on("$ccls/publishSkippedRanges", function(params)
      skipped[params.uri] = params.skippedRanges
      if params.uri == soda.lsp.uri() then
        paint_skipped()
      end
    end)
    soda.hook("focus", ".*", function()
      if skipped[soda.lsp.uri() or ""] then
        paint_skipped()
      end
    end)
  end
  for _, language in ipairs(options.languages or { "cpp" }) do
    soda.lsp.server(language, options.command or { "ccls" }, {
      init = options.init,
      settings = options.settings,
      roots = options.roots or { ".ccls-root", ".ccls", "compile_commands.json" },
      -- It indexes the whole root: not a directory merely around a file.
      auto = options.auto == nil and "marked" or options.auto,
      -- The `ccls` keymap holds in its documents, whatever runs it.
      name = "ccls",
    })
  end
end

return M
