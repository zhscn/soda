-- Language server features over soda.lsp, which keeps documents in step and
-- passes messages. clangd runs for C++; for anything else, name a server:
--
--   soda.lsp.server("rust", { "rust-analyzer" })
--
-- rust-analyzer is not on by default: it runs a project's build scripts,
-- which is not something opening a file should do.
--
-- Built in: <a-.> goes to the definition, <a-?> lists references, <a-,> comes
-- back; K shows what the caret is on; <space>c and <space>C list the callers
-- and the callees. Completion follows from the server being there.

soda.lsp.server("cpp", { "clangd", "--header-insertion=never", "--function-arg-placeholders=1" })

local diagnostics = {}

local function path_of(uri)
  return (uri:gsub("^file://", ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end
local function relative(path)
  local root = soda.val("root")
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

-- A column in the server's counting, from a zero-based byte offset in a line.
local function to_character(text, bytes, encoding)
  if encoding == "utf-8" then
    return bytes
  end
  local units = 0
  for _, code in utf8.codes(text:sub(1, bytes), true) do
    units = units + (encoding == "utf-32" and 1 or (code > 0xFFFF and 2 or 1))
  end
  return units
end
-- The zero-based byte offset of a server's column.
local function to_byte(text, character, encoding)
  if encoding == "utf-8" then
    return math.min(character, #text)
  end
  local units = 0
  for at, code in utf8.codes(text, true) do
    if units >= character then
      return at - 1
    end
    units = units + (encoding == "utf-32" and 1 or (code > 0xFFFF and 2 or 1))
  end
  return #text
end

local function here()
  local info, uri = soda.lsp.info(), soda.lsp.uri()
  if not info or not uri then
    return nil
  end
  local buf = soda.buffer()
  local _, head = buf:selection()
  return {
    textDocument = { uri = uri },
    position = {
      line = head[1] - 1,
      character = to_character(buf:line(head[1]), head[2] - 1, info.encoding),
    },
  }
end

-- Asks about the caret; says so if there is nobody to ask.
local function ask(method, extend, answer)
  local params = here()
  if not params then
    soda.message("No language server for this document")
    return
  end
  for key, value in pairs(extend or {}) do
    params[key] = value
  end
  local function respond(result, failure)
    if failure then
      soda.message(method .. ": " .. tostring(failure.message))
    else
      answer(result)
    end
  end
  if not soda.lsp.request(method, params, respond) then
    soda.message("No language server for this document")
  end
end

local function lines_of(path)
  local lines, file = {}, io.open(path)
  if file then
    for line in file:lines() do
      table.insert(lines, line)
    end
    file:close()
  end
  return lines
end
-- Grouped result lines from { path, line, column, text } entries, zero-based.
-- Without text, a row shows the line of the file.
local function show(kind, entries)
  table.sort(entries, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  local rows, current, source = {}, nil, nil
  for _, entry in ipairs(entries) do
    if entry.path ~= current then
      if current then
        table.insert(rows, "")
      end
      current, source = entry.path, lines_of(entry.path)
      table.insert(rows, relative(entry.path))
    end
    local text = entry.text or (source[entry.line + 1] or ""):gsub("^%s+", "")
    table.insert(rows, string.format("  %d:%d  %s", entry.line + 1, entry.column + 1, text))
  end
  soda.results(kind, rows)
end

local function location_entry(location)
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange
  return { path = path_of(uri), line = range.start.line, column = range.start.character }
end
local function open_location(location)
  local entry = location_entry(location)
  local lines = lines_of(entry.path)
  local byte = to_byte(lines[entry.line + 1] or "", entry.column, soda.lsp.info().encoding)
  soda.open(entry.path, entry.line + 1, byte + 1)
end

soda.define_command("lsp-definition", function()
  ask("textDocument/definition", nil, function(result)
    if result and result.uri then
      result = { result }
    end
    if not result or #result == 0 then
      soda.message("No definition found")
    elseif #result == 1 then
      open_location(result[1])
    else
      local entries = {}
      for _, location in ipairs(result) do
        table.insert(entries, location_entry(location))
      end
      show("definitions", entries)
    end
  end)
end)

soda.define_command("lsp-references", function()
  ask("textDocument/references", { context = { includeDeclaration = true } }, function(result)
    local entries = {}
    for _, location in ipairs(result or {}) do
      table.insert(entries, location_entry(location))
    end
    show("references", entries)
  end)
end)

local function hierarchy(kind, method, field)
  ask("textDocument/prepareCallHierarchy", nil, function(items)
    if not items or #items == 0 then
      soda.message("No call hierarchy here")
      return
    end
    local function listed(result)
      local entries = {}
      for _, call in ipairs(result or {}) do
        local item = call[field]
        local range = field == "from" and call.fromRanges[1] or item.selectionRange
        table.insert(entries, {
          path = path_of(item.uri),
          line = range.start.line,
          column = range.start.character,
          text = item.name,
        })
      end
      show(kind, entries)
    end
    soda.lsp.request(method, { item = items[1] }, function(result, failure)
      if failure then
        soda.message(method .. ": " .. tostring(failure.message))
      else
        listed(result)
      end
    end)
  end)
end
soda.define_command("lsp-callers", function()
  hierarchy("callers", "callHierarchy/incomingCalls", "from")
end)
soda.define_command("lsp-callees", function()
  hierarchy("callees", "callHierarchy/outgoingCalls", "to")
end)

soda.define_command("lsp-hover", function()
  ask("textDocument/hover", nil, function(result)
    local contents = result and result.contents
    if type(contents) == "table" then
      contents = contents.value or (contents[1] and (contents[1].value or contents[1]))
    end
    if type(contents) ~= "string" or contents == "" then
      soda.message("Nothing known here")
      return
    end
    -- The message line shows one line; the whole of it is in `messages`.
    soda.message((contents:gsub("%s*\n%s*", " ")))
  end)
end)

local function flag_current()
  local uri = soda.lsp.uri()
  if not uri then
    return
  end
  soda.unflag("lsp-error")
  soda.unflag("lsp-warning")
  local errors, warnings = {}, {}
  for _, diagnostic in ipairs(diagnostics[uri] or {}) do
    local line = diagnostic.range.start.line + 1
    table.insert(diagnostic.severity == 1 and errors or warnings, line)
  end
  if #errors > 0 then
    soda.flag("lsp-error", "error", "E", errors)
  end
  if #warnings > 0 then
    soda.flag("lsp-warning", "todo", "W", warnings)
  end
end
soda.lsp.on("textDocument/publishDiagnostics", function(params)
  diagnostics[params.uri] = params.diagnostics
  if params.uri == soda.lsp.uri() then
    flag_current()
  end
end)
soda.hook("focus", ".*", flag_current)

soda.define_command("lsp-diagnostics", function()
  local entries = {}
  for uri, list in pairs(diagnostics) do
    for _, diagnostic in ipairs(list) do
      table.insert(entries, {
        path = path_of(uri),
        line = diagnostic.range.start.line,
        column = diagnostic.range.start.character,
        text = (diagnostic.message:gsub("\n.*", "")),
      })
    end
  end
  show("diagnostics", entries)
end)

soda.define_command("lsp-restart", function()
  soda.lsp.restart()
end)

soda.completion.register({
  triggers = { ".", ">", ":" },
  complete = function(context, sink)
    local trigger = context.trigger
    local line = trigger and soda.buffer():line(context.line) or ""
    local before = line:sub(math.max(context.column - 2, 1), context.column - 1)
    if (trigger == ">" and before ~= "->") or (trigger == ":" and before ~= "::") then
      sink:done()
      return
    end
    local params = here()
    if not params then
      sink:done()
      return
    end
    local asked = soda.lsp.request("textDocument/completion", params, function(result)
      local list = result and (result.items or result) or {}
      local items = {}
      for _, item in ipairs(list) do
        local edit = item.textEdit
        local text = edit and edit.newText or item.insertText or item.label
        local candidate = {
          label = (item.label:gsub("^%s+", "")),
          filter = item.filterText,
          detail = item.detail,
        }
        if item.insertTextFormat == 2 then
          candidate.snippet = text
        else
          candidate.text = text
        end
        table.insert(items, candidate)
      end
      sink:add(items)
      sink:done({ incomplete = result and result.isIncomplete })
    end)
    if not asked then
      sink:done()
    end
  end,
})

soda.command("map normal <a-.> lsp-definition")
soda.command("map normal <a-?> lsp-references")
soda.command("map normal K lsp-hover")
soda.command("map normal <space>c lsp-callers")
soda.command("map normal <space>C lsp-callees")
