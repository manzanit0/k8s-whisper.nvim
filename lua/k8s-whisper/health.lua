local curl = require 'plenary.curl'
local M = {}

M.check = function()
  vim.health.start('k8s-whisper.nvim')

  -- Get configuration from the main whisper module
  local whisper = require('k8s-whisper')
  local config = whisper.config

  -- Test schema catalog connectivity
  local url = config.github_base_api_url .. '/' .. config.schemas_catalog .. '/git/trees/' .. config.schema_catalog_ref

  local ok, response = pcall(function()
    return curl.get(url, { headers = config.github_headers, query = { recursive = 1 } })
  end)

  if not ok then
    vim.health.error('Failed to connect to schema catalog: ' .. tostring(response))
    return
  end

  if response.status == 200 then
    vim.health.ok('Schema catalog is reachable (' .. config.schemas_catalog .. ')')
  else
    vim.health.error('Schema catalog returned status ' .. response.status .. ' (' .. config.schemas_catalog .. ')')
  end
end

return M
