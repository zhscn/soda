-- Language server features over soda.lsp, which keeps documents in step and
-- passes messages. clangd runs for C++; for anything else, name a server:
--
--   soda.lsp.server("rust", { "rust-analyzer" })
--
-- rust-analyzer is not on by default: it runs a project's build scripts,
-- which is not something opening a file should do.
--
-- Built in: <a-.> goes to the definition, <a-?> lists references, <a-,> comes
-- back. Under the leader (SPC, which is <c-c>): k shows what the caret is on
-- in a box until the next key; c and C list the callers and the callees; R
-- renames and a offers code actions; s and S find symbols; h switches header
-- and source; . goes to the implementations.
-- Completion follows from the server being there.

soda.lsp.server("cpp", { "clangd", "--function-arg-placeholders=1" })

-- What `require("lsp")` returns, filled in at the end; `token_category`
-- can be replaced from there.
local module = {}
local diagnostics = {}
local severities = { "error", "warning" }

local function path_of(uri)
  local path = uri:gsub("^file://", ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  -- A directory's URI may end in a slash.
  return #path > 1 and path:gsub("/+$", "") or path
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

-- Requests still waiting, by what they are for: a newer request for the
-- same thing cancels the older, whose answer nobody wants any more.
local pending = {}
-- `buf` names the document whose server to ask, when not the current one.
local function send(slot, method, params, answer, buf)
  soda.lsp.cancel(pending[slot])
  local id
  id = soda.lsp.request(method, params, function(result, failure)
    if pending[slot] == id then
      pending[slot] = nil
    end
    answer(result, failure)
  end, buf)
  pending[slot] = id or nil
  return id
end

-- The capability a server declares for each standard request; a server
-- that does not declare one is not asked.
local providers = {
  ["textDocument/definition"] = "definitionProvider",
  ["textDocument/declaration"] = "declarationProvider",
  ["textDocument/typeDefinition"] = "typeDefinitionProvider",
  ["textDocument/implementation"] = "implementationProvider",
  ["textDocument/documentHighlight"] = "documentHighlightProvider",
  ["textDocument/references"] = "referencesProvider",
  ["textDocument/hover"] = "hoverProvider",
  ["textDocument/rename"] = "renameProvider",
  ["textDocument/prepareRename"] = "renameProvider",
  ["textDocument/codeAction"] = "codeActionProvider",
  ["textDocument/formatting"] = "documentFormattingProvider",
  ["textDocument/rangeFormatting"] = "documentRangeFormattingProvider",
  ["textDocument/documentSymbol"] = "documentSymbolProvider",
  ["textDocument/prepareCallHierarchy"] = "callHierarchyProvider",
  ["textDocument/signatureHelp"] = "signatureHelpProvider",
  ["textDocument/completion"] = "completionProvider",
  ["workspace/symbol"] = "workspaceSymbolProvider",
}
-- Whether the current server can answer `method`; says so when it cannot.
local function supports(method, quiet)
  local info = soda.lsp.info()
  if not info then
    if not quiet then
      soda.message("No language server for this document")
    end
    return false
  end
  local provider = providers[method]
  if provider and not info.capabilities[provider] then
    if not quiet then
      soda.message("The language server does not offer " .. method)
    end
    return false
  end
  return true
end
-- Why a request failed, in words.
local function failed(method, failure)
  if failure.code == -32601 then
    return "The language server does not offer " .. method
  end
  return method .. ": " .. tostring(failure.message)
end

-- Asks about the caret; says so if there is nobody to ask.
local function ask(method, extend, answer)
  local params = here()
  if not params then
    soda.message("No language server for this document")
    return
  end
  if not supports(method) then
    return
  end
  for key, value in pairs(extend or {}) do
    params[key] = value
  end
  local function respond(result, failure)
    if failure then
      soda.message(failed(method, failure))
    else
      answer(result)
    end
  end
  if not send(method, method, params, respond) then
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
-- Goes to a location; `buf` names whose server counted its columns, when
-- that is not the current document's.
local function open_location(location, buf)
  local entry = location_entry(location)
  local lines = lines_of(entry.path)
  local info = soda.lsp.info(buf)
  local byte = to_byte(lines[entry.line + 1] or "", entry.column, info and info.encoding or "utf-16")
  soda.open(entry.path, entry.line + 1, byte + 1)
end

-- Goes to a place the server names, or lists them when there are several.
local function go_to(command, method, kind)
  soda.define_command(command, "Go to the " .. kind .. " of the symbol", function()
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
go_to("lsp-implementation", "textDocument/implementation", "implementation")

soda.define_command("lsp-references", "List references to the symbol", function()
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
soda.define_command("lsp-callers", "List the functions calling this one", function()
  hierarchy("callers", "callHierarchy/incomingCalls", "from")
end)
soda.define_command("lsp-callees", "List the functions this one calls", function()
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

soda.define_command("lsp-hover", "Show the server's documentation for the symbol", function()
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
  -- Unused code shows dim and what is deprecated struck through, apart
  -- from the severity's underline.
  local tagged = {}
  for _, diagnostic in ipairs(diagnostics[uri] or {}) do
    local severity = severities[diagnostic.severity] or "info"
    table.insert(lines[severity], diagnostic.range.start.line + 1)
    local from, to = place(diagnostic.range.start), place(diagnostic.range["end"])
    if from[1] == to[1] and from[2] == to[2] then
      to[2] = to[2] + 1 -- An empty range still marks a cell.
    end
    -- Places it speaks of, such as an earlier declaration, follow it.
    local text = diagnostic.message
    for _, related in ipairs(diagnostic.relatedInformation or {}) do
      local location = related.location
      text = text .. "\n" .. relative(path_of(location.uri)) .. ":"
        .. (location.range.start.line + 1) .. ": " .. related.message
    end
    table.insert(notes, {
      from = from,
      to = to,
      severity = severity,
      text = text,
    })
    for _, tag in ipairs(diagnostic.tags or {}) do
      local face = ({ "unnecessary", "deprecated" })[tag]
      if face then
        table.insert(tagged, { from = from, to = to, face = face })
      end
    end
  end
  soda.note("lsp", notes)
  soda.paint("lsp-tags", tagged)
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
-- The category a token shows in, from its type and the set of its
-- modifiers; nil keeps the highlighting it has. A read-only variable reads
-- as a constant.
function module.token_category(type, modifiers)
  if modifiers.readonly and (type == "variable" or type == "property") then
    return "constant"
  end
  return token_categories[type]
end
local function show_tokens(buf, data, legend, encoding)
  -- One name for each type and set of modifiers that occurs.
  local names, slots = {}, {}
  local modifier_names = legend.tokenModifiers or {}
  local deprecated = nil
  for index, name in ipairs(modifier_names) do
    if name == "deprecated" then
      deprecated = 1 << (index - 1)
    end
  end
  local function slot(type_index, bits)
    local key = type_index .. ":" .. bits
    if not slots[key] then
      local modifiers = {}
      for index, name in ipairs(modifier_names) do
        if bits & (1 << (index - 1)) ~= 0 then
          modifiers[name] = true
        end
      end
      local type = legend.tokenTypes[type_index + 1]
      table.insert(names, type and module.token_category(type, modifiers) or "")
      slots[key] = #names - 1
    end
    return slots[key]
  end
  local struck = {}
  local count, tokens = buf:line_count(), {}
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
      tokens[size + 4] = slot(data[at + 3], data[at + 4])
      if deprecated and data[at + 4] & deprecated ~= 0 then
        table.insert(struck, { from = { line + 1, from + 1 }, to = { line + 1, to + 1 }, face = "deprecated" })
      end
    end
  end
  soda.tokens(tokens, names)
  soda.paint("lsp-deprecated", struck)
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

-- The last tokens of each document and the server's name for them, so that
-- the next answer can be only what changed.
local token_results = {}
-- Old token data with a server's edits made: each replaces `deleteCount`
-- numbers from `start` (zero-based) with its own `data`.
local function apply_token_edits(old, edits)
  table.sort(edits, function(a, b)
    return a.start < b.start
  end)
  local new, size, at = {}, 0, 0
  for _, edit in ipairs(edits) do
    table.move(old, at + 1, edit.start, size + 1, new)
    size = size + math.max(edit.start - at, 0)
    for _, number in ipairs(edit.data or {}) do
      size = size + 1
      new[size] = number
    end
    at = edit.start + (edit.deleteCount or 0)
  end
  table.move(old, at + 1, #old, size + 1, new)
  return new
end
local function ask_tokens(buf, uri, info, revision)
  local provider = info.capabilities.semanticTokensProvider
  local full = provider.full
  local previous = token_results[uri]
  local method = "textDocument/semanticTokens/full"
  local params = { textDocument = { uri = uri } }
  if type(full) == "table" and full.delta and previous and previous.id then
    method = method .. "/delta"
    params.previousResultId = previous.id
  end
  send("tokens " .. uri, method, params, function(result, failure)
    if failure or not result then
      -- The server may have forgotten what the edits would be against.
      token_results[uri] = nil
      return
    end
    local data = result.data
    if result.edits then
      if not previous then
        return
      end
      data = apply_token_edits(previous.data, result.edits)
    end
    data = data or {}
    token_results[uri] = { id = result.resultId, data = data }
    -- Kept even for text that has changed: the server counts from it.
    if buf:revision() == revision then
      show_tokens(buf, data, provider.legend, info.encoding)
    end
  end)
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
  if info.capabilities.semanticTokensProvider then
    ask_tokens(buf, uri, info, revision)
  end
  if info.capabilities.inlayHintProvider then
    local whole = {
      start = { line = 0, character = 0 },
      ["end"] = { line = buf:line_count(), character = 0 },
    }
    local params = { textDocument = document, range = whole }
    send("inlays " .. uri, "textDocument/inlayHint", params, function(result)
      if buf:revision() == revision then
        show_inlays(buf, result, info.encoding)
      end
    end)
  end
end

-- Servers that wait to be asked for diagnostics are asked when typing
-- pauses and when a document comes into view, once for each revision.
local pulled = {}
local function pull_diagnostics()
  local uri, info = soda.lsp.uri(), soda.lsp.info()
  if not uri or not info or not info.capabilities.diagnosticProvider then
    return
  end
  local buf = soda.buffer()
  local revision = buf:revision()
  local last = pulled[uri]
  if last and last.revision == revision then
    return
  end
  local params = { textDocument = { uri = uri }, previousResultId = last and last.id }
  send("pull " .. uri, "textDocument/diagnostic", params, function(report)
    if not report then
      return
    end
    pulled[uri] = { revision = revision, id = report.resultId }
    if report.kind == "full" then
      diagnostics[uri] = report.items or {}
    end
    if uri == soda.lsp.uri() then
      flag_current()
      decorate()
    end
  end)
end
soda.hook("idle", ".*", pull_diagnostics)
-- The server knows something changed, such as a header: ask again.
soda.lsp.on("workspace/diagnostic/refresh", function()
  pulled = {}
  pull_diagnostics()
end)

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
  pull_diagnostics()
end)

soda.define_command("lsp-diagnostics", "List the server's diagnostics", function()
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

-- A file's text with a server's edits made.
local function edited_text(text, edits, encoding)
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

local function read_file(path)
  local file, failure = io.open(path, "rb")
  if not file then
    return nil, failure
  end
  local text = file:read("a")
  file:close()
  return text
end

-- Whether `path` is `under` or inside it; the rest of the path if so.
local function inside(path, under)
  if path == under then
    return ""
  end
  if path:sub(1, #under + 1) == under .. "/" then
    return path:sub(#under + 1)
  end
end

-- A WorkspaceEdit as steps in order: a file's edits, or a file created,
-- renamed or deleted.
local function steps_of(edit)
  local steps = {}
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.kind then
        table.insert(steps, change)
      else
        table.insert(steps, { kind = "edit", uri = change.textDocument.uri, edits = change.edits })
      end
    end
  else
    for uri, edits in pairs(edit.changes or {}) do
      table.insert(steps, { kind = "edit", uri = uri, edits = edits })
    end
  end
  return steps
end

-- What to do for a WorkspaceEdit, worked out against the files as each step
-- leaves them, or nil and why it cannot be done. Nothing is touched yet.
local function plan_edit(steps, encoding)
  -- Each step changes what a path holds: { buf }, { text }, { directory },
  -- or false for nothing. Earlier states come from the steps before, and
  -- from the files themselves.
  local history, actions = {}, {}
  local function look(path)
    for at = #history, 1, -1 do
      local change = history[at]
      if change.set == path then
        return change.value
      elseif change.gone and inside(path, change.gone) then
        return false
      elseif change.to then
        local rest = inside(path, change.to)
        if rest then
          path = change.from .. rest
        end
      end
    end
    local buf = soda.buffer(path)
    if buf then
      return { buf = buf }
    end
    local kind = soda.file_kind(path)
    if kind == "directory" then
      return { directory = true }
    elseif kind == "file" then
      return { disk = path }
    end
    return false
  end
  local open, written, made, created, renamed, deleted = {}, {}, {}, 0, 0, 0
  for _, step in ipairs(steps) do
    local options = step.options or {}
    if step.kind == "edit" then
      local path = path_of(step.uri)
      local now = look(path)
      if not now or now.directory then
        return nil, path .. " does not exist"
      end
      if now.buf then
        table.insert(actions, { buf = now.buf, edits = step.edits })
        open[now.buf.id] = true
      else
        local text = now.text
        if not text then
          local failure
          text, failure = read_file(now.disk)
          if not text then
            return nil, tostring(failure)
          end
        end
        text = edited_text(text, step.edits, encoding)
        table.insert(history, { set = path, value = { text = text } })
        table.insert(actions, { write = path, text = text })
        -- A file this edit creates is counted once, as created.
        written[path] = not made[path] or nil
      end
    elseif step.kind == "create" then
      local path = path_of(step.uri)
      local now = look(path)
      if not now or options.overwrite then
        if now and now.buf then
          table.insert(actions, { buf = now.buf, clear = true })
          open[now.buf.id] = true
        else
          table.insert(history, { set = path, value = { text = "" } })
          table.insert(actions, { create = path })
          made[path] = true
          created = created + 1
        end
      elseif not options.ignoreIfExists then
        return nil, path .. " already exists"
      end
    elseif step.kind == "rename" then
      local from, to = path_of(step.oldUri), path_of(step.newUri)
      if not look(from) then
        return nil, from .. " does not exist"
      end
      local skip = false
      if look(to) and not options.overwrite then
        if not options.ignoreIfExists then
          return nil, to .. " already exists"
        end
        skip = true
      end
      if not skip then
        table.insert(history, { gone = to })
        table.insert(history, { from = from, to = to })
        table.insert(actions, { from = from, to = to })
        renamed = renamed + 1
      end
    elseif step.kind == "delete" then
      local path = path_of(step.uri)
      local now = look(path)
      if now then
        table.insert(history, { gone = path })
        table.insert(actions, { delete = path, recursive = options.recursive })
        deleted = deleted + 1
      elseif not options.ignoreIfNotExists then
        return nil, path .. " does not exist"
      end
    else
      return nil, "unknown change " .. tostring(step.kind)
    end
  end
  local count = function(set)
    local n = 0
    for _ in pairs(set) do
      n = n + 1
    end
    return n
  end
  return actions, {
    open = count(open),
    written = count(written),
    created = created,
    renamed = renamed,
    deleted = deleted,
  }
end

-- A file URI, as the editor makes them.
local function uri_of(path)
  return "file://" .. path:gsub("[^%w/%-_%.~]", function(byte)
    return string.format("%%%02X", byte:byte())
  end)
end

-- Glob patterns as the protocol has them: `*` and `?` within a name, `**`
-- across directories, `[...]` and `{a,b}`.
local function expand_braces(glob)
  local from, to = glob:find("%b{}")
  if not from then
    return { glob }
  end
  local out = {}
  for option in (glob:sub(from + 1, to - 1) .. ","):gmatch("([^,]*),") do
    for _, each in ipairs(expand_braces(glob:sub(1, from - 1) .. option .. glob:sub(to + 1))) do
      table.insert(out, each)
    end
  end
  return out
end
local function glob_at(p, pi, s, si)
  if pi > #p then
    return si > #s
  end
  local c = p:sub(pi, pi)
  if c == "*" then
    local double = p:sub(pi + 1, pi + 1) == "*"
    local after = pi + (double and 2 or 1)
    if double and p:sub(after, after) == "/" and glob_at(p, after + 1, s, si) then
      return true
    end
    local at = si
    while true do
      if glob_at(p, after, s, at) then
        return true
      end
      if at > #s or (not double and s:sub(at, at) == "/") then
        return false
      end
      at = at + 1
    end
  elseif c == "?" then
    return si <= #s and s:sub(si, si) ~= "/" and glob_at(p, pi + 1, s, si + 1)
  elseif c == "[" then
    local close = p:find("]", pi + 2, true)
    if close then
      local class = p:sub(pi + 1, close - 1):gsub("^!", "^"):gsub("%%", "%%%%")
      return si <= #s and s:sub(si, si):find("[" .. class .. "]") ~= nil
        and glob_at(p, close + 1, s, si + 1)
    end
  end
  return s:sub(si, si) == c and glob_at(p, pi + 1, s, si + 1)
end
local function glob_matches(glob, path, ignore_case)
  if ignore_case then
    glob, path = glob:lower(), path:lower()
  end
  for _, each in ipairs(expand_braces(glob)) do
    if glob_at(each, 1, path, 1) then
      return true
    end
  end
  return false
end

-- Tells the server about files an edit wrote, created, renamed or deleted:
-- through its file watchers, and the file operations it asked to hear of.
-- `done` holds { kind, path, to, folder } in the order they happened.
local function announce(done)
  local info = soda.lsp.info()
  if not info or #done == 0 then
    return
  end
  -- Watchers: created 1, changed 2, deleted 3; a watcher's kind is a mask
  -- of created 1, changed 2 and deleted 4.
  local changes = {}
  local function watched(path, change)
    for _, watcher in ipairs(info.watchers or {}) do
      local pattern, under = watcher.globPattern, path
      if type(pattern) == "table" then
        local base = path_of(type(pattern.baseUri) == "table" and pattern.baseUri.uri or pattern.baseUri)
        local rest = inside(path, base)
        under, pattern = rest and rest:gsub("^/", ""), pattern.pattern
      end
      local mask = ({ 1, 2, 4 })[change]
      if under and (watcher.kind or 7) & mask ~= 0 and glob_matches(pattern, under) then
        table.insert(changes, { uri = uri_of(path), type = change })
        return
      end
    end
  end
  local operations = (info.capabilities.workspace or {}).fileOperations or {}
  local function wanted(registration, path, folder)
    for _, filter in ipairs(registration and registration.filters or {}) do
      local pattern = filter.pattern
      local kind = pattern.matches
      if (filter.scheme == nil or filter.scheme == "file")
        and (kind == nil or (kind == "folder") == folder)
        and glob_matches(pattern.glob, path, pattern.options and pattern.options.ignoreCase)
      then
        return true
      end
    end
    return false
  end
  local created, renamed, deleted = {}, {}, {}
  for _, entry in ipairs(done) do
    if entry.kind == "changed" then
      watched(entry.path, 2)
    elseif entry.kind == "created" then
      watched(entry.path, 1)
      if wanted(operations.didCreate, entry.path, entry.folder) then
        table.insert(created, { uri = uri_of(entry.path) })
      end
    elseif entry.kind == "renamed" then
      watched(entry.path, 3)
      watched(entry.to, 1)
      if wanted(operations.didRename, entry.path, entry.folder) then
        table.insert(renamed, { oldUri = uri_of(entry.path), newUri = uri_of(entry.to) })
      end
    elseif entry.kind == "deleted" then
      watched(entry.path, 3)
      if wanted(operations.didDelete, entry.path, entry.folder) then
        table.insert(deleted, { uri = uri_of(entry.path) })
      end
    end
  end
  if #changes > 0 then
    soda.lsp.notify("workspace/didChangeWatchedFiles", { changes = changes })
  end
  if #created > 0 then
    soda.lsp.notify("workspace/didCreateFiles", { files = created })
  end
  if #renamed > 0 then
    soda.lsp.notify("workspace/didRenameFiles", { files = renamed })
  end
  if #deleted > 0 then
    soda.lsp.notify("workspace/didDeleteFiles", { files = deleted })
  end
end

-- Applies a WorkspaceEdit: open documents through their buffers, so that it
-- can be undone, other files on disk, and files created, renamed and
-- deleted in order. Nothing is applied unless all of it can be. `origin` is
-- a buffer and revision the answer was asked for.
local function apply_edit(edit, origin)
  if origin and origin.buffer:revision() ~= origin.revision then
    soda.message("Not applied: the document changed in the meantime")
    return false
  end
  local info = soda.lsp.info()
  local encoding = info and info.encoding or "utf-8"
  local actions, counts = plan_edit(steps_of(edit), encoding)
  if not actions then
    soda.message("Not applied: " .. counts)
    return false
  end
  -- What reached the disk, for the server; told even when a later step
  -- fails, since that much happened.
  local done = {}
  for _, action in ipairs(actions) do
    local ok, failure = pcall(function()
      if action.buf and action.clear then
        local whole = { start = { line = 0, character = 0 }, ["end"] = { line = 1 / 0, character = 0 } }
        action.buf:edit(buffer_changes(action.buf, { { range = whole, newText = "" } }, encoding))
      elseif action.buf then
        action.buf:edit(buffer_changes(action.buf, action.edits, encoding))
      elseif action.write then
        local file = assert(io.open(action.write, "wb"))
        file:write(action.text)
        file:close()
        table.insert(done, { kind = "changed", path = action.write })
      elseif action.create then
        soda.create_file(action.create)
        table.insert(done, { kind = "created", path = action.create, folder = false })
      elseif action.from then
        soda.rename_file(action.from, action.to)
        local folder = soda.file_kind(action.to) == "directory"
        table.insert(done, { kind = "renamed", path = action.from, to = action.to, folder = folder })
      elseif action.delete then
        local folder = soda.file_kind(action.delete) == "directory"
        soda.delete_file(action.delete, action.recursive)
        table.insert(done, { kind = "deleted", path = action.delete, folder = folder })
      end
    end)
    if not ok then
      announce(done)
      soda.message("Partly applied: " .. tostring(failure))
      return false
    end
  end
  announce(done)
  local parts = {}
  local function part(n, words)
    if n > 0 then
      table.insert(parts, n .. " " .. words)
    end
  end
  part(counts.open, "open")
  part(counts.written, "written to disk")
  part(counts.created, "created")
  part(counts.renamed, "renamed")
  part(counts.deleted, "deleted")
  local summary
  if counts.created + counts.renamed + counts.deleted > 0 then
    -- A renamed file may be edited too, so there is no one total.
    summary = "Applied: " .. table.concat(parts, ", ")
  else
    local total = counts.open + counts.written
    summary = "Applied to " .. total .. (total == 1 and " file" or " files")
    if counts.written > 0 then
      summary = summary .. ": " .. table.concat(parts, ", ")
    end
  end
  soda.message(summary)
  return true
end

-- The server learns whether its edit went in.
soda.lsp.on("workspace/applyEdit", function(params)
  return { applied = apply_edit(params.edit) }
end)

soda.define_command("lsp-rename", "Rename the symbol across the project", function(name)
  name = (name or ""):match("^%s*(.-)%s*$")
  if name == "" then
    local info = soda.lsp.info()
    local provider = info and info.capabilities.renameProvider
    if type(provider) ~= "table" or not provider.prepareProvider then
      soda.prompt("lsp-rename " .. soda.val("word"))
      return
    end
    -- The server says first whether there is something to rename, and
    -- what it is called now.
    local buf = soda.buffer()
    ask("textDocument/prepareRename", nil, function(result)
      if not result then
        soda.message("Nothing to rename here")
        return
      end
      local current = result.placeholder
      local range = result.range or (result.start and result)
      if not current and range and range.start.line == range["end"].line then
        local text = buf:line(range.start.line + 1)
        local from = to_byte(text, range.start.character, info.encoding)
        local to = to_byte(text, range["end"].character, info.encoding)
        current = text:sub(from + 1, to)
      end
      soda.prompt("lsp-rename " .. (current or soda.val("word")))
    end)
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
  -- An action may come without its edit, which the server works out when
  -- it is chosen.
  local info = soda.lsp.info()
  local provider = info and info.capabilities.codeActionProvider
  if action.edit == nil and action.data ~= nil and type(provider) == "table" and provider.resolveProvider then
    local asked = send("codeAction/resolve", "codeAction/resolve", action, function(resolved, failure)
      if failure then
        soda.message(failed("codeAction/resolve", failure))
      elseif resolved then
        resolved.data = nil
        perform(resolved, origin)
      end
    end)
    if not asked then
      soda.message("No language server for this document")
    end
    return
  end
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

soda.define_command("lsp-code-action", "Pick one of the server's code actions", function()
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

soda.define_command("lsp-format", "Format the selection, or else the buffer, with the language server", function()
  local buf = soda.buffer()
  local origin = { buffer = buf, revision = buf:revision() }
  local uri = soda.lsp.uri()
  local info = soda.lsp.info()
  local options = { tabSize = soda.option("indent-width"), insertSpaces = true }
  local method, extend = "textDocument/formatting", { options = options }
  -- A selection formats only its lines, when the server can.
  local anchor, head = buf:selection()
  local selected = anchor[1] ~= head[1] or anchor[2] ~= head[2]
  if selected and info and info.capabilities.documentRangeFormattingProvider then
    if anchor[1] > head[1] or (anchor[1] == head[1] and anchor[2] > head[2]) then
      anchor, head = head, anchor
    end
    local function position(place)
      local text = buf:line(math.min(place[1], buf:line_count()))
      return { line = place[1] - 1, character = to_character(text, place[2] - 1, info.encoding) }
    end
    method = "textDocument/rangeFormatting"
    extend.range = { start = position(anchor), ["end"] = position(head) }
  end
  ask(method, extend, function(edits)
    if not edits or #edits == 0 then
      soda.message("Already formatted")
    else
      apply_edit({ changes = { [uri] = edits } }, origin)
    end
  end)
end)

soda.define_command("lsp-switch", "Switch between a header and its source", function()
  local uri = soda.lsp.uri()
  local asked = uri
    and soda.lsp.request("textDocument/switchSourceHeader", { uri = uri }, function(result, failure)
      if failure then
        soda.message(failed("textDocument/switchSourceHeader", failure))
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

soda.define_command("lsp-symbols", "List the symbols of the document", function()
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

soda.define_command("lsp-workspace-symbols", "Search the symbols of the project", function(query)
  query = (query or ""):match("^%s*(.-)%s*$")
  if query == "" then
    soda.prompt("lsp-workspace-symbols ")
    return
  end
  if not supports("workspace/symbol") then
    return
  end
  local asked = soda.lsp.request("workspace/symbol", { query = query }, function(result, failure)
    if failure then
      soda.message(failed("workspace/symbol", failure))
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
  -- A parameter may be where it stands in the label rather than its words.
  if type(name) == "table" and name[1] and name[2] then
    local info = soda.lsp.info()
    local encoding = info and info.encoding or "utf-16"
    local from, to = to_byte(label, name[1], encoding), to_byte(label, name[2], encoding)
    return label:sub(1, from) .. "[" .. label:sub(from + 1, to) .. "]" .. label:sub(to + 1)
  end
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
      if params and supports("textDocument/signatureHelp", true) then
        send("signature", "textDocument/signatureHelp", params, function(result)
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

-- When typing pauses, the other places of the symbol at the caret, as the
-- server finds them: where it is written apart from where it is read.
soda.declare_option("lsp-highlight", {
  default = true,
  doc = "Highlight the places of the symbol at the caret as the language server finds them",
})
soda.hook("idle", ".*", function()
  local buf = soda.buffer()
  if not soda.option("lsp-highlight") then
    soda.paint("lsp-highlight", {})
    return
  end
  local params = here()
  if not params or not supports("textDocument/documentHighlight", true) then
    return
  end
  local revision = buf:revision()
  local encoding = soda.lsp.info().encoding
  send("highlight", "textDocument/documentHighlight", params, function(result)
    -- An answer about text that has changed would mark the wrong places,
    -- and paints go to the current document.
    if soda.buffer() ~= buf or buf:revision() ~= revision then
      return
    end
    local count, spans = buf:line_count(), {}
    local function place(position)
      local line = math.min(position.line + 1, count)
      return { line, to_byte(buf:line(line), position.character, encoding) + 1 }
    end
    for _, highlight in ipairs(result or {}) do
      table.insert(spans, {
        from = place(highlight.range.start),
        to = place(highlight.range["end"]),
        face = highlight.kind == 3 and "reference-write" or "reference",
      })
    end
    soda.paint("lsp-highlight", spans)
  end)
end)

-- Work a server reports, such as indexing, on the status line: the latest
-- of each piece of work, until it ends.
local progress, order = {}, {}
local function show_progress()
  local shown = nil
  for _, token in ipairs(order) do
    local work = progress[token]
    if work then
      local words = { work.title }
      if work.message and work.message ~= "" then
        table.insert(words, work.message)
      end
      if work.percentage then
        table.insert(words, math.floor(work.percentage) .. "%")
      end
      shown = table.concat(words, " ")
    end
  end
  soda.status("lsp-progress", shown)
end
soda.lsp.on("$/progress", function(params)
  local token, value = tostring(params.token), params.value or {}
  if value.kind == "begin" then
    if not progress[token] then
      table.insert(order, token)
    end
    progress[token] = { title = value.title or "", message = value.message, percentage = value.percentage }
  elseif value.kind == "report" and progress[token] then
    local work = progress[token]
    work.message = value.message or work.message
    work.percentage = value.percentage or work.percentage
  elseif value.kind == "end" then
    progress[token] = nil
    for at, each in ipairs(order) do
      if each == token then
        table.remove(order, at)
        break
      end
    end
  end
  show_progress()
end)
-- What a server says for the user goes to the message line; what it logs,
-- to the message log only.
soda.lsp.on("window/showMessage", function(params)
  soda.message(params.message)
end)
soda.lsp.on("window/logMessage", function(params)
  soda.log(params.message)
end)
-- A question with choices cannot wait for an answer here: the server waits
-- for this function. It is shown, and answered as dismissed.
soda.lsp.on("window/showMessageRequest", function(params)
  soda.message(params.message)
end)
soda.lsp.on("window/showDocument", function(params)
  if params.external then
    return { success = false }
  end
  local path = path_of(params.uri)
  local range = params.selection
  soda.open(path, range and range.start.line + 1 or 1, 1)
  return { success = true }
end)

soda.hook("save", ".*", function()
  local uri = soda.lsp.uri()
  if uri then
    soda.lsp.notify("textDocument/didSave", { textDocument = { uri = uri } })
  end
end)

soda.define_command("lsp-restart", "Restart the language server", function()
  soda.lsp.restart()
end)

-- Documentation as text, from a string or MarkupContent.
local function text_of(documentation)
  if type(documentation) == "table" then
    return documentation.value
  end
  return documentation
end

-- A candidate's ranges as the completion list counts them: bytes before the
-- word it replaces, and bytes after the caret for Enter (insert) and Tab
-- (replace). `line` is the line as it was asked about, `caret` a zero-based
-- byte in it. A single range is where Enter ends; Tab still takes the rest
-- of the word.
local function spans(range, line, caret, prefix, row, encoding)
  local insert, replace = range, nil
  if range.insert then
    insert, replace = range.insert, range.replace
  end
  if insert.start.line ~= row or insert["end"].line ~= row then
    return nil
  end
  local start = to_byte(line, insert.start.character, encoding)
  local after = function(position)
    if position and position.line == row then
      return math.max(to_byte(line, position.character, encoding) - caret, 0)
    end
  end
  return math.max(caret - start - #prefix, 0), after(insert["end"]), after(replace and replace["end"])
end

-- The items of the latest answer, for resolving the one selected.
local listed = {}

soda.completion.register({
  triggers = { ".", ">", ":" },
  complete = function(context, sink)
    local trigger = context.trigger
    local buf = soda.buffer()
    local line = buf:line(context.line)
    local before = line:sub(math.max(context.column - 2, 1), context.column - 1)
    if (trigger == ">" and before ~= "->") or (trigger == ":" and before ~= "::") then
      sink:done()
      return
    end
    local params = here()
    local info = soda.lsp.info()
    if not params or not info or not supports("textDocument/completion", true) then
      sink:done()
      return
    end
    local encoding = info.encoding
    local provider = info.capabilities.completionProvider or {}
    local asked = send("completion", "textDocument/completion", params, function(result)
      local list = result and (result.items or result) or {}
      local defaults = result and result.itemDefaults or {}
      local everywhere = provider.allCommitCharacters
      local items = {}
      listed = list
      for index, item in ipairs(list) do
        local edit = item.textEdit
        local range = edit and (edit.range or edit) or defaults.editRange
        local text = edit and edit.newText or item.textEditText or item.insertText or item.label
        local candidate = {
          label = (item.label:gsub("^%s+", "")),
          filter = item.filterText,
          detail = item.detail,
          doc = text_of(item.documentation),
        }
        if (item.insertTextFormat or defaults.insertTextFormat) == 2 then
          candidate.snippet = text
        else
          candidate.text = text
        end
        if range then
          candidate.back, candidate.insert, candidate.replace =
            spans(range, line, context.column - 1, context.prefix, context.line - 1, encoding)
        end
        local commit = item.commitCharacters or defaults.commitCharacters or everywhere
        if commit then
          candidate.commit = table.concat(commit)
        end
        if provider.resolveProvider then
          candidate.key = index
        end
        -- Made with the candidate in one step, such as the `#include` the
        -- name needs.
        if item.additionalTextEdits and #item.additionalTextEdits > 0 then
          candidate.edits = buffer_changes(buf, item.additionalTextEdits, encoding)
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
  -- Documentation the server leaves out of the list until asked.
  resolve = function(key, done)
    local item = listed[key]
    if not item then
      return
    end
    send("resolve", "completionItem/resolve", item, function(result)
      if result then
        done({ detail = result.detail, doc = text_of(result.documentation) })
      end
    end)
  end,
})

soda.map("normal", "<a-.>", "lsp-definition")
soda.map("normal", "<a-?>", "lsp-references")
soda.map("global", "<c-c>.", "lsp-implementation")
soda.map("global", "<c-c>k", "lsp-hover")
soda.map("global", "<c-c>c", "lsp-callers")
soda.map("global", "<c-c>C", "lsp-callees")
soda.map("global", "<c-c>R", "lsp-rename")
soda.map("global", "<c-c>a", "lsp-code-action")
soda.map("global", "<c-c>s", "lsp-symbols")
soda.map("global", "<c-c>S", "lsp-workspace-symbols")
soda.map("global", "<c-c>h", "lsp-switch")

-- What modules for one server's extensions, such as `ccls`, build on.
for name, value in pairs({
  path_of = path_of,
  uri_of = uri_of,
  relative = relative,
  to_byte = to_byte,
  to_character = to_character,
  here = here,
  send = send,
  supports = supports,
  failed = failed,
  show = show,
  location_entry = location_entry,
  open_location = open_location,
}) do
  module[name] = value
end
return module
