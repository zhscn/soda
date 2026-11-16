-- clice extensions for C/C++. Enable with require("clice").setup().
local lsp = require("lsp")
local M = {}
local call_type = 3

local function request(method, params, done, origin)
  return lsp.send(method, method, params, function(result, failure)
    if failure then
      soda.message(lsp.failed(method, failure))
    else
      done(result)
    end
  end, origin)
end

local function document(done)
  local origin, uri = soda.buffer(), soda.lsp.uri()
  if not uri or not soda.lsp.info() then
    soda.message("No language server for this document")
    return
  end
  done(uri, origin)
end

local function label(item)
  return (item.label or "") .. " — " .. (item.description or "")
end

local function choose(prompt, items, describe, done)
  local titles = {}
  for i, item in ipairs(items) do
    titles[i] = i .. ". " .. describe(item)
  end
  if #titles == 0 then
    soda.message("No " .. prompt .. " available")
    return
  end
  soda.choose(prompt, titles, function(_, index) done(items[index]) end)
end

local function node(item)
  local children
  if item.children and #item.children > 0 then
    children = {}
    for _, child in ipairs(item.children) do
      table.insert(children, node(child))
    end
  end
  local detail = ""
  if item.location then
    local place = lsp.location_entry(item.location)
    detail = lsp.relative(place.path) .. ":" .. (place.line + 1)
  end
  return { label = item.name or "", detail = detail, children = children,
    expanded = children ~= nil, leaf = (item.numChildren or 0) == 0, item = item }
end

for name, method in pairs({ callers = "$clice/caller", callees = "$clice/callee" }) do
  soda.define_command("clice-" .. name, "Explore clice " .. name, function(mask)
    mask = mask and mask:match("%S+")
    local family = call_type
    if mask then family = tonumber(mask) end
    if not family or family % 1 ~= 0 or family < 0 or family > 3 then
      soda.message("Call type must be 0 (direct), 1 (bases), 2 (derived), or 3 (both)")
      return
    end
    local params, origin = lsp.here(), soda.buffer()
    if not params then
      soda.message("No language server for this document")
      return
    end
    params.hierarchy, params.levels, params.callType = true, 1, family
    request(method, params, function(root)
      if not root or not root.id then
        soda.message("No indexed function here")
        return
      end
      soda.tree({ name = "clice-" .. name, roots = { node(root) },
        expand = function(row, add)
          local asked = lsp.send(method .. " " .. row.item.id, method,
            { id = row.item.id, hierarchy = true, levels = 1, callType = family },
            function(result, failure)
              local children = {}
              if failure then soda.message(lsp.failed(method, failure)) end
              for _, child in ipairs(result and result.children or {}) do
                table.insert(children, node(child))
              end
              add(children)
            end, origin)
          if not asked then add({}) end
        end,
        open = function(row)
          if row.item.location then lsp.open_location(row.item.location, origin) end
        end,
      })
    end, origin)
  end, { args = { { name = "CALL_TYPE", optional = true, choices = { "0", "1", "2", "3" } } } })
end

soda.define_command("clice-context", "Show the compilation context and command", function()
  document(function(uri, origin)
    request("clice/currentContext", { uri = uri }, function(result)
      if not result then return end
      local lines = { result.context and label(result.context) or "Automatic file context",
        result.automatic and "Picked automatically" or "Chosen explicitly" }
      if result.inactiveChoice then table.insert(lines, "Inactive choice: " .. label(result.inactiveChoice)) end
      local command = result.command
      if command then
        table.insert(lines, "Command source: " .. command.source)
        table.insert(lines, "Directory: " .. command.directory)
        if command.from then table.insert(lines, "From: " .. command.from) end
        -- Quote each argument so spaces and escapes stay unambiguous.
        for _, argument in ipairs(command.arguments or {}) do
          table.insert(lines, string.format("%q", argument))
        end
        if command.queryFailure then table.insert(lines, "Compiler query: " .. command.queryFailure) end
      end
      soda.popup(table.concat(lines, "\n"))
    end, origin)
  end)
end)

soda.define_command("clice-reset-context", "Use the automatic compilation context", function()
  document(function(uri, origin)
    request("clice/resetContext", { uri = uri }, function() soda.message("Using automatic context") end, origin)
  end)
end)

soda.define_command("clice-switch-context", "Choose a compilation context", function()
  document(function(uri, origin)
    local function listing(attempt)
      local items, epoch = {}, nil
      local function page(offset)
        request("clice/queryContext", { uri = uri, offset = offset }, function(result)
          if not result then return end
          if epoch and epoch ~= result.epoch then
            if attempt < 3 then listing(attempt + 1)
            else soda.message("Compilation contexts keep changing; try again") end
            return
          end
          epoch = result.epoch
          for _, item in ipairs(result.contexts or {}) do table.insert(items, item) end
          if #(result.contexts or {}) > 0 and #items < result.total then
            page(#items)
            return
          end
          table.insert(items, 1, { automatic = true })
          choose("compilation context", items, function(item)
            return item.automatic and "Automatic" or label(item)
          end, function(item)
            if item.automatic then
              request("clice/resetContext", { uri = uri }, function() soda.message("Using automatic context") end, origin)
              return
            end
            request("clice/switchContext", { uri = uri, contextUri = item.uri, epoch = epoch,
              occurrence = item.occurrence, commandHash = item.commandHash }, function(result)
              soda.message(result and result.stale and "Compilation contexts changed; select again"
                or result and result.success and label(item) or "Could not switch context")
            end, origin)
          end)
        end, origin)
      end
      page(0)
    end
    listing(1)
  end)
end)

soda.define_command("clice-other-contexts", "Toggle navigation across compilation contexts", function()
  document(function(uri, origin)
    request("clice/currentContext", { uri = uri }, function(result)
      if not result then return end
      local show = not result.otherContexts
      request("clice/showOtherContexts", { uri = uri, show = show }, function()
        soda.message(show and "Showing all compilation contexts" or "Showing current compilation context")
      end, origin)
    end, origin)
  end)
end)

soda.define_command("clice-configuration", "Choose a build configuration", function()
  document(function(uri, origin)
    request("clice/listConfigurations", { uri = uri }, function(result)
      if not result then return end
      choose("build configuration", result.configurations or {}, function(name)
        return name .. (name == result.active and " (active)" or "")
          .. (name == result.defaultConfiguration and " (default)" or "")
      end, function(name)
        request("clice/switchConfiguration", { uri = uri, name = name }, function(answer)
          if not answer or not answer.success then
            soda.message(answer and answer.reason or "Configuration switch failed")
          end
        end, origin)
      end)
    end, origin)
  end)
end)

soda.define_command("clice-switch", "Switch source, header or module counterpart", function()
  document(function(uri, origin)
    request("clice/counterparts", { uri = uri }, function(result)
      if not result then return end
      local function open(target)
        lsp.open_location({ uri = target, range = { start = { line = 0, character = 0 } } }, origin)
      end
      if result.preferred then open(result.preferred)
      else
        choose("counterpart", result.candidates or {}, function(item)
          return lsp.path_of(item.uri) .. " — " .. table.concat(item.reasons or {}, ", ")
        end, function(item) open(item.uri) end)
      end
    end, origin)
  end)
end)

soda.define_command("clice-refactor", "Choose a refactoring of the given kind", function(kind)
  lsp.code_action(kind and kind:match("%S+") or "refactor")
end, { args = { { name = "KIND", optional = true } } })
soda.define_command("clice-base", "Show base types", function() soda.command("lsp-supertypes") end)
soda.define_command("clice-derived", "Show derived types", function() soda.command("lsp-subtypes") end)

local started = false
function M.setup(options)
  options = options or {}
  if options.call_type ~= nil then
    assert(type(options.call_type) == "number" and options.call_type % 1 == 0
      and options.call_type >= 0 and options.call_type <= 3, "call_type must be an integer from 0 to 3")
    call_type = options.call_type
  end
  if not started then
    soda.keymap("clice", { server = "clice", doc = "Documents clice serves" })
    started = true
  end
  for _, language in ipairs(options.languages or { "cpp" }) do
    soda.lsp.server(language, options.command or { "clice", "serve" }, {
      init = options.init, settings = options.settings, auto = options.auto, name = "clice",
      roots = options.roots or { "clice.toml", ".clice/config.toml", "compile_commands.json", "git" },
    })
  end
end
return M
