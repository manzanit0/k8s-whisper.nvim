local curl = require 'plenary.curl'

-- Default configuration
local default_config = {
  schemas_catalog = 'datreeio/CRDs-catalog',
  schema_catalog_ref = 'main',
  github_base_api_url = 'https://api.github.com/repos',
  github_headers = {
    Accept = 'application/vnd.github+json',
    ['X-GitHub-Api-Version'] = '2022-11-28',
  },
}

local M = {
  config = vim.deepcopy(default_config),
  schema_cache = {}, -- Cache for downloaded schemas
}

-- Setup function to configure the plugin
M.setup = function(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend('force', default_config, opts)
  M.schema_url = 'https://raw.githubusercontent.com/' .. M.config.schemas_catalog .. '/' .. M.config.schema_catalog_ref
end

-- Initialize with default config
M.schema_url = 'https://raw.githubusercontent.com/' .. M.config.schemas_catalog .. '/' .. M.config.schema_catalog_ref

-- Download and cache the list of CRDs
M.list_github_tree = function()
  if M.schema_cache.trees then
    return M.schema_cache.trees -- Return cached data if available
  end

  local url = M.config.github_base_api_url .. '/' .. M.config.schemas_catalog .. '/git/trees/' .. M.config.schema_catalog_ref
  local response = curl.get(url, { headers = M.config.github_headers, query = { recursive = 1 } })
  local body = vim.fn.json_decode(response.body)
  local trees = {}
  for _, tree in ipairs(body.tree) do
    if tree.type == 'blob' and tree.path:match '%.json$' then
      table.insert(trees, tree.path)
    end
  end
  M.schema_cache.trees = trees -- Cache the list of CRDs
  return trees
end

-- Extract apiVersion and kind from YAML content, handling multiple resources
M.extract_api_version_and_kind = function(buffer_content)
  -- Split the content by document separators (---)
  local documents = {}
  local current_doc = ""

  for line in buffer_content:gmatch("[^\n]*") do
    if line:match("^%-%-%-%s*$") then
      if current_doc:match("%S") then -- Only add non-empty documents
        table.insert(documents, current_doc)
      end
      current_doc = ""
    else
      current_doc = current_doc .. line .. "\n"
    end
  end

  -- Add the last document if it exists
  if current_doc:match("%S") then
    table.insert(documents, current_doc)
  end

  -- If no documents were found, treat the entire content as one document
  if #documents == 0 then
    documents = { buffer_content }
  end

  -- Extract apiVersion and kind from each document
  local resources = {}
  for _, doc in ipairs(documents) do
    local api_version = doc:match('apiVersion:%s*([%w%.%/%-]+)')
    local kind = doc:match('kind:%s*([%w%-]+)')
    if api_version and kind then
      table.insert(resources, { api_version = api_version, kind = kind })
    end
  end

  return resources
end

-- Normalize apiVersion and kind to match CRD schema naming convention
M.normalize_crd_name = function(api_version, kind)
  if not api_version or not kind then
    return nil
  end
  -- Split apiVersion into group and version (e.g., "argoproj.io/v1alpha1" -> "argoproj.io", "v1alpha1")
  local group, version = api_version:match('([^/]+)/([^/]+)')
  if not group or not version then
    return nil
  end
  -- Normalize kind to lowercase
  local normalized_kind = kind:lower()
  -- Construct the CRD name in the format: <group>/<kind>_<version>.json
  return group .. '/' .. normalized_kind .. '_' .. version .. '.json'
end

-- Match the CRD schema based on apiVersion and kind
M.match_crd = function(buffer_content)
  local resources = M.extract_api_version_and_kind(buffer_content)
  if not resources or #resources == 0 then
    return nil
  end

  local all_crds = M.list_github_tree()
  local matched_crds = {}

  for _, resource in ipairs(resources) do
    local crd_name = M.normalize_crd_name(resource.api_version, resource.kind)
    if crd_name then
      for _, crd in ipairs(all_crds) do
        if crd:match(crd_name) then
          table.insert(matched_crds, { crd = crd, resource = resource })
          break
        end
      end
    end
  end

  return matched_crds
end

-- Attach a schema to the buffer
M.attach_schema = function(schema_url, description, buffer_path)
  local clients = vim.lsp.get_clients({ name = 'yamlls' })
  if #clients == 0 then
    vim.notify('yaml-language-server is not active.', vim.log.levels.WARN)
    return
  end
  local yaml_client = clients[1]

  -- Update the yaml.schemas setting for the current buffer
  yaml_client.config.settings = yaml_client.config.settings or {}
  yaml_client.config.settings.yaml = yaml_client.config.settings.yaml or {}
  yaml_client.config.settings.yaml.schemas = yaml_client.config.settings.yaml.schemas or {}

  -- Attach the schema only for the current buffer
  yaml_client.config.settings.yaml.schemas[schema_url] = buffer_path

  -- Notify the server of the configuration change
  yaml_client.notify('workspace/didChangeConfiguration', {
    settings = yaml_client.config.settings,
  })
  vim.notify('Attached schema: ' .. description, vim.log.levels.INFO)
end

-- Get the correct Kubernetes schema URL based on apiVersion and kind
M.get_kubernetes_schema_url = function(api_version, kind)
  local version = api_version:match('/([%w%-]+)$') or api_version
  local schema_name

  -- Check if the schema file exists with the version suffix
  schema_name = kind:lower() .. '-' .. version .. '.json'
  local url_with_version = 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master/' ..
      schema_name

  -- Check if the schema file exists without the version suffix
  local url_without_version = 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master/' ..
      kind:lower() .. '.json'

  -- Try to fetch the schema with the version suffix first
  local response_with_version = curl.get(url_with_version, { headers = M.config.github_headers })
  if response_with_version.status == 200 then
    return url_with_version
  end

  -- If the schema with the version suffix doesn't exist, try without the version suffix
  local response_without_version = curl.get(url_without_version, { headers = M.config.github_headers })
  if response_without_version.status == 200 then
    return url_without_version
  end

  -- If neither exists, return nil or fallback to a default schema
  return nil
end

M.init = function(bufnr)
  -- Check if the schema has already been attached to this buffer
  if vim.b[bufnr].schema_attached then
    return
  end
  local buffer_path = vim.api.nvim_buf_get_name(bufnr)
  vim.b[bufnr].schema_attached = true -- Mark the schema as attached

  local buffer_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local matched_crds = M.match_crd(buffer_content)

  if matched_crds and #matched_crds > 0 then
    -- Attach schemas for all matched CRDs
    for _, match in ipairs(matched_crds) do
      local schema_url = M.schema_url .. '/' .. match.crd
      M.attach_schema(schema_url, 'CRD schema for ' .. match.resource.kind, buffer_path)
    end
  else
    -- Check if the file contains Kubernetes YAML resources
    local resources = M.extract_api_version_and_kind(buffer_content)
    if resources and #resources > 0 then
      local attached_any = false
      for _, resource in ipairs(resources) do
        -- Attach the Kubernetes schema
        local kubernetes_schema_url = M.get_kubernetes_schema_url(resource.api_version, resource.kind)
        if kubernetes_schema_url then
          M.attach_schema(kubernetes_schema_url, 'Kubernetes schema for ' .. resource.kind, buffer_path)
          attached_any = true
        end
      end

      if not attached_any then
        vim.notify('No Kubernetes schemas found for any resources in this file', vim.log.levels.WARN)
      end
    else
      -- Fall back to the default LSP configuration
      vim.notify('No CRD or Kubernetes schema found. Falling back to default LSP configuration.', vim.log.levels.WARN)
    end
  end
end

return M
