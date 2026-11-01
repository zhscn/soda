-- Snippets as completion candidates, per language. None are built in: add
-- yours from init.lua, by a language's id, or "*" for every language:
--
--   require("snippets").add("cpp", {
--     fori = "for (int ${1:i} = 0; ${1:i} < ${2:n}; ++${1:i}) {\n\t$0\n}",
--   })
--
-- Typing a name lists its snippet; Tab takes it and goes through its places.

local M = {}
local snippets = {}

function M.add(language, table_of_snippets)
  snippets[language] = snippets[language] or {}
  for name, body in pairs(table_of_snippets) do
    snippets[language][name] = body
  end
end

soda.completion.register({
  complete = function(context, sink)
    local items = {}
    for _, language in ipairs({ context.language, "*" }) do
      for name, body in pairs(snippets[language] or {}) do
        table.insert(items, { label = name, snippet = body, detail = "snippet" })
      end
    end
    if #items > 0 then
      sink:add(items)
    end
    sink:done()
  end,
})

return M
