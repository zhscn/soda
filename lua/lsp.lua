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
-- and the callees; <space>R renames and <space>a offers code actions;
-- <space>s and <space>S find symbols; <space>h switches header and source.
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

-- Goes to a place the server names, or lists them when there are several.
local function go_to(command, method, kind)
  soda.define_command(command, function()
    ask(method, nil, function(result)
      if result and (result.uri or result.targetUri) then
        result = { result }
      end
      if not result or #result == 0 then
        soda.message("No " .. kind .. " found")
      elseif #result == 1 then
        open_location(result[1])
      else
        local entries = {}
        for _, location in ipairs(result) do
          table.insert(entries, location_entry(location))
        end
        show(kind .. "s", entries)
      end
    end)
  end)
end
go_to("lsp-definition", "textDocument/definition", "definition")
go_to("lsp-declaration", "textDocument/declaration", "declaration")
go_to("lsp-type-definition", "textDocument/typeDefinition", "type definition")

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
-- How a server's token types show; the rest keep their highlighting.
local token_categories = {
  namespace = "namespace", type = "type", class = "type", enum = "type", interface = "type",
  struct = "type", typeParameter = "type", concept = "type", parameter = "parameter",
  enumMember = "constant", ["function"] = "function", method = "function", macro = "macro",
  comment = "comment",
}
local function show_tokens(buf, result, legend, encoding)
  local names = {}
  for index, name in ipairs(legend.tokenTypes) do
    names[index] = token_categories[name] or ""
  end
  local count, tokens = buf:line_count(), {}
  local data = result.data or {}
  local line, character, row, text = 0, 0, nil, nil
  for at = 1, #data, 5 do
    if data[at] > 0 then
      line, character = line + data[at], 0
    end
    character = character + data[at + 1]
    if line < count then
      if row ~= line then
        row, text = line, buf:line(line + 1)
      end
      local from = to_byte(text, character, encoding)
      local to = to_byte(text, character + data[at + 2], encoding)
      local size = #tokens
      tokens[size + 1], tokens[size + 2], tokens[size + 3] = line, from, to
      tokens[size + 4] = data[at + 3]
    end
  end
  soda.tokens(tokens, names)
end

local function show_inlays(buf, result, encoding)
  local count, hints = buf:line_count(), {}
  for _, hint in ipairs(result or {}) do
    local line = hint.position.line + 1
    if line <= count then
      local label = hint.label
      if type(label) == "table" then
        local parts = {}
        for _, part in ipairs(label) do
          table.insert(parts, part.value)
        end
        label = table.concat(parts)
      end
      table.insert(hints, {
        line = line,
        column = to_byte(buf:line(line), hint.position.character, encoding) + 1,
        text = (hint.paddingLeft and " " or "") .. label .. (hint.paddingRight and " " or ""),
      })
    end
  end
  soda.inlays(hints)
end

-- Asks for what is drawn over the text. A server reports diagnostics when it
-- has finished with a change, so that is when to ask. An answer about text
-- that has changed since would land in the wrong places, and is dropped.
local function decorate()
  local uri, info = soda.lsp.uri(), soda.lsp.info()
  if not uri or not info then
    return
  end
  local buf = soda.buffer()
  local revision = buf:revision()
  local document = { uri = uri }
  local provider = info.capabilities.semanticTokensProvider
  if provider then
    local params = { textDocument = document }
    soda.lsp.request("textDocument/semanticTokens/full", params, function(result)
      if result and buf:revision() == revision then
        show_tokens(buf, result, provider.legend, info.encoding)
      end
    end)
  end
  if info.capabilities.inlayHintProvider then
    local whole = {
      start = { line = 0, character = 0 },
      ["end"] = { line = buf:line_count(), character = 0 },
    }
    local params = { textDocument = document, range = whole }
    soda.lsp.request("textDocument/inlayHint", params, function(result)
      if buf:revision() == revision then
        show_inlays(buf, result, info.encoding)
      end
    end)
  end
end

soda.lsp.on("textDocument/publishDiagnostics", function(params)
  diagnostics[params.uri] = params.diagnostics
  if params.uri == soda.lsp.uri() then
    flag_current()
    decorate()
  end
end)
soda.hook("focus", ".*", function()
  flag_current()
  decorate()
end)

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

soda.define_command("lsp-format", function()
  local buf = soda.buffer()
  local origin = { buffer = buf, revision = buf:revision() }
  local uri = soda.lsp.uri()
  local options = { tabSize = tonumber(soda.option("indent-width")), insertSpaces = true }
  ask("textDocument/formatting", { options = options }, function(edits)
    if not edits or #edits == 0 then
      soda.message("Already formatted")
    else
      apply_edit({ changes = { [uri] = edits } }, origin)
    end
  end)
end)

soda.define_command("lsp-switch", function()
  local uri = soda.lsp.uri()
  local asked = uri
    and soda.lsp.request("textDocument/switchSourceHeader", { uri = uri }, function(result, failure)
      if failure then
        soda.message(tostring(failure.message))
      elseif result then
        soda.open(path_of(result))
      else
        soda.message("No matching header or source")
      end
    end)
  if not asked then
    soda.message("No language server for this document")
  end
end)

local symbol_kinds = {
  [2] = "module", [3] = "namespace", [5] = "class", [6] = "method", [8] = "field",
  [9] = "constructor", [10] = "enum", [12] = "function", [13] = "variable",
  [14] = "constant", [22] = "enumerator", [23] = "struct", [26] = "template",
}
-- Rows for a document's symbols; children follow their parents, indented.
local function outline(symbols, depth, rows)
  for _, symbol in ipairs(symbols) do
    local kind = symbol_kinds[symbol.kind]
    table.insert(rows, {
      title = string.rep("  ", depth) .. symbol.name .. (kind and "  " .. kind or ""),
      place = (symbol.selectionRange or symbol.location.range).start,
    })
    outline(symbol.children or {}, depth + 1, rows)
  end
  return rows
end

soda.define_command("lsp-symbols", function()
  local buf = soda.buffer()
  local path = path_of(soda.lsp.uri() or "")
  ask("textDocument/documentSymbol", nil, function(result)
    local rows = outline(result or {}, 0, {})
    if #rows == 0 then
      soda.message("No symbols here")
      return
    end
    local titles = {}
    for _, row in ipairs(rows) do
      table.insert(titles, row.title)
    end
    soda.choose("symbol", titles, function(index)
      local place = rows[index].place
      local encoding = soda.lsp.info().encoding
      local line = math.min(place.line + 1, buf:line_count())
      soda.open(path, line, to_byte(buf:line(line), place.character, encoding) + 1)
    end)
  end)
end)

soda.define_command("lsp-workspace-symbols", function(query)
  query = (query or ""):match("^%s*(.-)%s*$")
  if query == "" then
    soda.prompt("lsp-workspace-symbols ")
    return
  end
  local asked = soda.lsp.request("workspace/symbol", { query = query }, function(result, failure)
    if failure then
      soda.message(tostring(failure.message))
      return
    end
    local entries = {}
    for _, symbol in ipairs(result or {}) do
      local entry = location_entry(symbol.location)
      local container = symbol.containerName
      entry.text = (container and container ~= "" and container .. "::" or "") .. symbol.name
      table.insert(entries, entry)
    end
    show("symbols", entries)
  end)
  if not asked then
    soda.message("No language server for this document")
  end
end)

-- The signature being called, with the argument at the caret in brackets.
local function signature_of(help)
  local signature = help and help.signatures and help.signatures[(help.activeSignature or 0) + 1]
  if not signature then
    return nil
  end
  local active = signature.activeParameter or help.activeParameter or 0
  local parameter = signature.parameters and signature.parameters[active + 1]
  local name = parameter and parameter.label
  local label = signature.label
  if type(name) == "string" then
    local from, to = label:find(name, 1, true)
    if from then
      return label:sub(1, from - 1) .. "[" .. name .. "]" .. label:sub(to + 1)
    end
  end
  return label
end

-- Typing a call shows its signature on the message row; it stays while the
-- arguments are typed, so a popup, which any key closes, would not do.
soda.completion.register({
  triggers = { "(", ",", ")" },
  complete = function(context, sink)
    sink:done()
    if context.trigger == ")" then
      soda.hint(nil)
    elseif context.trigger then
      local params = here()
      if params then
        soda.lsp.request("textDocument/signatureHelp", params, function(result)
          soda.hint(signature_of(result))
        end)
      end
    end
  end,
})
soda.hook("mode", ".*", function(mode)
  if mode ~= "insert" then
    soda.hint(nil)
  end
end)

soda.hook("save", ".*", function()
  local uri = soda.lsp.uri()
  if uri then
    soda.lsp.notify("textDocument/didSave", { textDocument = { uri = uri } })
  end
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
soda.command("map normal <space>s lsp-symbols")
soda.command("map normal <space>S lsp-workspace-symbols")
soda.command("map normal <space>h lsp-switch")
