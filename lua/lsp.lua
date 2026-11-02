-- Language server features over soda.lsp, which keeps documents in step and
-- passes messages. clangd runs for C++; for anything else, name a server:
--
--   soda.lsp.server("rust", { "rust-analyzer" })
--
-- rust-analyzer is not on by default: it runs a project's build scripts,
-- which is not something opening a file should do.
--
-- Built in: <a-.> goes to the definition, <a-?> lists references, <a-,> comes
-- back; K shows what the caret is on in a box until the next key; <space>c and <space>C list the callers
-- and the callees; <space>R renames and <space>a offers code actions.
-- Completion follows from the server being there.

soda.lsp.server("cpp", { "clangd", "--header-insertion=never", "--function-arg-placeholders=1" })

local diagnostics = {}
local severities = { "error", "warning" }

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

-- The diagnostics of the caret's line, above what the server says.
local function with_problems(contents)
  local words = {}
  local _, head = soda.buffer():selection()
  for _, diagnostic in ipairs(diagnostics[soda.lsp.uri()] or {}) do
    if diagnostic.range.start.line == head[1] - 1 then
      table.insert(words, diagnostic.message)
    end
  end
  if contents ~= "" then
    if #words > 0 then
      table.insert(words, "")
    end
    table.insert(words, contents)
  end
  return table.concat(words, "\n")
end

soda.define_command("lsp-hover", function()
  ask("textDocument/hover", nil, function(result)
    local contents = result and result.contents
    if type(contents) == "table" then
      contents = contents.value or (contents[1] and (contents[1].value or contents[1]))
    end
    if type(contents) ~= "string" or contents == "" then
      local problems = with_problems("")
      if problems == "" then
        soda.message("Nothing known here")
      else
        soda.popup(problems)
      end
      return
    end
    soda.popup(with_problems(contents))
  end)
end)

local function flag_current()
  local uri = soda.lsp.uri()
  if not uri then
    return
  end
  soda.unflag("lsp-error")
  soda.unflag("lsp-warning")
  soda.unflag("lsp-info")
  local notes = {}
  local lines = { error = {}, warning = {}, info = {} }
  local buf = soda.buffer()
  local info = soda.lsp.info()
  local function place(position)
    -- Diagnostics can arrive for text that has since gone.
    local line = position.line + 1
    local text = line <= buf:line_count() and buf:line(line) or ""
    return { line, to_byte(text, position.character, info and info.encoding or "utf-8") + 1 }
  end
  for _, diagnostic in ipairs(diagnostics[uri] or {}) do
    local severity = severities[diagnostic.severity] or "info"
    table.insert(lines[severity], diagnostic.range.start.line + 1)
    local from, to = place(diagnostic.range.start), place(diagnostic.range["end"])
    if from[1] == to[1] and from[2] == to[2] then
      to[2] = to[2] + 1 -- An empty range still marks a cell.
    end
    table.insert(notes, {
      from = from,
      to = to,
      severity = severity,
      text = diagnostic.message,
    })
  end
  soda.note("lsp", notes)
  -- Later groups win a line, so the worst goes last.
  if #lines.info > 0 then
    soda.flag("lsp-info", "info", "I", lines.info)
  end
  if #lines.warning > 0 then
    soda.flag("lsp-warning", "todo", "W", lines.warning)
  end
  if #lines.error > 0 then
    soda.flag("lsp-error", "error", "E", lines.error)
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

-- The edits of a WorkspaceEdit by URI, or nil and why it cannot be applied.
local function edits_of(edit)
  local files = {}
  for uri, edits in pairs(edit.changes or {}) do
    files[uri] = edits
  end
  for _, change in ipairs(edit.documentChanges or {}) do
    if not change.textDocument then
      return nil, "it creates, renames or deletes files"
    end
    files[change.textDocument.uri] = change.edits
  end
  return files
end

-- Changes for an open document, in the order of `buf:edit`.
local function buffer_changes(buf, edits, encoding)
  local count = buf:line_count()
  local function place(position)
    local line = position.line + 1
    if line > count then
      -- The end of the document, which only a final newline puts on a line.
      if buf:text():sub(-1) == "\n" then
        return { count + 1, 1 }
      end
      return { count, #buf:line(count) + 1 }
    end
    return { line, to_byte(buf:line(line), position.character, encoding) + 1 }
  end
  local changes = {}
  for _, edit in ipairs(edits) do
    table.insert(changes, { place(edit.range.start), place(edit.range["end"]), edit.newText })
  end
  return changes
end

-- The new text of a file on disk, or nil and why not.
local function edited_file(path, edits, encoding)
  local file, failure = io.open(path, "rb")
  if not file then
    return nil, failure
  end
  local text = file:read("a")
  file:close()
  local starts, at = { 1 }, 1
  while true do
    local newline = text:find("\n", at, true)
    if not newline then
      break
    end
    at = newline + 1
    table.insert(starts, at)
  end
  local function offset(position)
    local start = starts[position.line + 1]
    if not start then
      return #text + 1
    end
    local line = text:sub(start, (starts[position.line + 2] or #text + 2) - 2)
    return start + to_byte(line, position.character, encoding)
  end
  local spans = {}
  for index, edit in ipairs(edits) do
    table.insert(spans, {
      from = offset(edit.range.start),
      to = offset(edit.range["end"]),
      text = edit.newText,
      index = index,
    })
  end
  -- From the end, so that earlier offsets hold; at one place, later edits go
  -- in first and the earlier ones end up before them.
  table.sort(spans, function(a, b)
    if a.from ~= b.from then
      return a.from > b.from
    end
    return a.index > b.index
  end)
  for _, span in ipairs(spans) do
    text = text:sub(1, span.from - 1) .. span.text .. text:sub(span.to)
  end
  return text
end

-- Applies a WorkspaceEdit: open documents through their buffers, so that it
-- can be undone, other files on disk. Nothing is applied unless all of it
-- can be. `origin` is a buffer and revision the answer was asked for.
local function apply_edit(edit, origin)
  local files, problem = edits_of(edit)
  if not files then
    soda.message("Not applied: " .. problem)
    return false
  end
  if origin and origin.buffer:revision() ~= origin.revision then
    soda.message("Not applied: the document changed in the meantime")
    return false
  end
  local info = soda.lsp.info()
  local encoding = info and info.encoding or "utf-8"
  local open, closed = {}, {}
  for uri, edits in pairs(files) do
    local path = path_of(uri)
    local buf = soda.buffer(path)
    if buf then
      table.insert(open, { buf = buf, changes = buffer_changes(buf, edits, encoding) })
    else
      local text, failure = edited_file(path, edits, encoding)
      if not text then
        soda.message("Not applied: " .. tostring(failure))
        return false
      end
      table.insert(closed, { path = path, text = text })
    end
  end
  for _, target in ipairs(open) do
    target.buf:edit(target.changes)
  end
  for _, target in ipairs(closed) do
    local file, failure = io.open(target.path, "wb")
    if not file then
      soda.message("Partly applied: " .. tostring(failure))
      return false
    end
    file:write(target.text)
    file:close()
  end
  local total = #open + #closed
  local summary = "Applied to " .. total .. (total == 1 and " file" or " files")
  if #closed > 0 then
    summary = summary .. ": " .. #open .. " open, " .. #closed .. " written to disk"
  end
  soda.message(summary)
  return true
end

soda.lsp.on("workspace/applyEdit", function(params)
  apply_edit(params.edit)
end)

soda.define_command("lsp-rename", function(name)
  name = (name or ""):match("^%s*(.-)%s*$")
  if name == "" then
    soda.prompt("lsp-rename " .. soda.val("word"))
    return
  end
  local buf = soda.buffer()
  local origin = { buffer = buf, revision = buf:revision() }
  ask("textDocument/rename", { newName = name }, function(result)
    if result then
      apply_edit(result, origin)
    else
      soda.message("Nothing to rename here")
    end
  end)
end)

local function perform(action, origin)
  if action.edit and not apply_edit(action.edit, origin) then
    return
  end
  -- An action is a command itself, or carries one to run after its edit.
  local command = type(action.command) == "table" and action.command or action
  if type(command.command) == "string" then
    soda.lsp.request("workspace/executeCommand", {
      command = command.command,
      arguments = command.arguments,
    }, function(_, failure)
      if failure then
        soda.message(tostring(failure.message))
      end
    end)
  end
end

soda.define_command("lsp-code-action", function()
  local buf = soda.buffer()
  local info = soda.lsp.info()
  if not info then
    soda.message("No language server for this document")
    return
  end
  local function position(place)
    local text = buf:line(math.min(place[1], buf:line_count()))
    return { line = place[1] - 1, character = to_character(text, place[2] - 1, info.encoding) }
  end
  local anchor, head = buf:selection()
  local first, last = position(anchor), position(head)
  if first.line > last.line or (first.line == last.line and first.character > last.character) then
    first, last = last, first
  end
  -- Fixes hang on diagnostics, so the server needs those of these lines.
  local nearby = {}
  for _, diagnostic in ipairs(diagnostics[soda.lsp.uri()] or {}) do
    local line = diagnostic.range.start.line
    if line >= first.line and line <= last.line then
      table.insert(nearby, diagnostic)
    end
  end
  local origin = { buffer = buf, revision = buf:revision() }
  ask("textDocument/codeAction", {
    range = { start = first, ["end"] = last },
    context = { diagnostics = soda.lsp.array(nearby) },
  }, function(result)
    local actions, titles = {}, {}
    for _, action in ipairs(result or {}) do
      if not action.disabled then
        table.insert(actions, action)
        table.insert(titles, action.title)
      end
    end
    if #actions == 0 then
      soda.message("No code actions here")
      return
    end
    soda.choose("code action", titles, function(index)
      perform(actions[index], origin)
    end)
  end)
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
soda.command("map normal <space>R lsp-rename")
soda.command("map normal <space>a lsp-code-action")
