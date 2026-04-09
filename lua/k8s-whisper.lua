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
  auto_insert_modeline = true, -- Automatically insert schema modeline comments
}

local M = {
  config = vim.deepcopy(default_config),
  schema_cache = {}, -- Cache for downloaded schemas
  refresh_timers = {}, -- Timers for debouncing refresh per buffer
  current_schemas = {}, -- Track currently attached schemas per buffer
  inserting_modelines = {}, -- Track when we're inserting modelines to prevent refresh loops
}

local ns = vim.api.nvim_create_namespace('k8s-whisper')

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
-- Returns array of resources with line numbers
M.extract_api_version_and_kind = function(buffer_content)
  local resources = {}
  local lines = vim.split(buffer_content, '\n', { plain = true })

  local current_doc_start = 1
  local current_api_version = nil
  local current_kind = nil
  local has_content = false

  for line_num, line in ipairs(lines) do
    -- Check for document separator
    if line:match("^%-%-%-%s*$") then
      -- Save previous document if it had content
      if has_content and current_api_version and current_kind then
        table.insert(resources, {
          api_version = current_api_version,
          kind = current_kind,
          start_line = current_doc_start,
        })
      end
      -- Start new document
      current_doc_start = line_num + 1
      current_api_version = nil
      current_kind = nil
      has_content = false
    else
      -- Check for apiVersion and kind
      if not current_api_version then
        local api_version = line:match('apiVersion:%s*([%w%.%/%-]+)')
        if api_version then
          current_api_version = api_version
        end
      end
      if not current_kind then
        local kind = line:match('kind:%s*([%w%-]+)')
        if kind then
          current_kind = kind
        end
      end
      -- Check if line has content
      if line:match("%S") then
        has_content = true
      end
    end
  end

  -- Don't forget the last document
  if has_content and current_api_version and current_kind then
    table.insert(resources, {
      api_version = current_api_version,
      kind = current_kind,
      start_line = current_doc_start,
    })
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

-- Clear all schemas for the current buffer
M.clear_schemas = function(bufnr)
  local clients = vim.lsp.get_clients({ name = 'yamlls' })
  if #clients == 0 then
    return
  end
  local yaml_client = clients[1]

  -- Get the buffer's file path
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == '' then
    return
  end

  -- Clear the schemas for this buffer
  if M.current_schemas[bufnr] then
    yaml_client.config.settings = yaml_client.config.settings or {}
    yaml_client.config.settings.yaml = yaml_client.config.settings.yaml or {}
    yaml_client.config.settings.yaml.schemas = yaml_client.config.settings.yaml.schemas or {}

    -- Only remove schema entries that point to this specific buffer's file
    for schema_url, _ in pairs(M.current_schemas[bufnr]) do
      if yaml_client.config.settings.yaml.schemas[schema_url] == bufname then
        yaml_client.config.settings.yaml.schemas[schema_url] = nil
      end
    end

    -- Notify the server of the configuration change
    yaml_client.notify('workspace/didChangeConfiguration', {
      settings = yaml_client.config.settings,
    })

    M.current_schemas[bufnr] = nil
  end
end

-- Attach multiple schemas to a buffer at once
M.attach_schemas = function(bufnr, schemas)
  if not schemas or #schemas == 0 then
    return
  end

  local clients = vim.lsp.get_clients({ name = 'yamlls' })
  if #clients == 0 then
    vim.notify('yaml-language-server is not active.', vim.log.levels.WARN)
    return
  end
  local yaml_client = clients[1]

  -- Get the buffer's file path
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == '' then
    return -- Skip buffers without a name
  end

  -- Update the yaml.schemas setting for the current buffer
  yaml_client.config.settings = yaml_client.config.settings or {}
  yaml_client.config.settings.yaml = yaml_client.config.settings.yaml or {}
  yaml_client.config.settings.yaml.schemas = yaml_client.config.settings.yaml.schemas or {}

  -- Attach all schemas for this specific buffer
  M.current_schemas[bufnr] = M.current_schemas[bufnr] or {}
  local descriptions = {}

  for _, schema in ipairs(schemas) do
    yaml_client.config.settings.yaml.schemas[schema.url] = bufname
    M.current_schemas[bufnr][schema.url] = true
    table.insert(descriptions, schema.description)
  end

  -- Notify the server of the configuration change
  yaml_client.notify('workspace/didChangeConfiguration', {
    settings = yaml_client.config.settings,
  })

  -- Show a single notification with all attached schemas
  if #descriptions == 1 then
    vim.notify('Attached schema: ' .. descriptions[1], vim.log.levels.INFO)
  else
    vim.notify('Attached ' .. #descriptions .. ' schemas: ' .. table.concat(descriptions, ', '), vim.log.levels.INFO)
  end
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

-- Insert schema modeline comments for each document in the buffer
M.insert_schema_modelines = function(bufnr, resource_schemas)
  if not M.config.auto_insert_modeline or #resource_schemas == 0 then
    return
  end

  -- Set flag to prevent refresh loop
  M.inserting_modelines[bufnr] = true

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modeline_pattern = '^#%s*yaml%-language%-server:%s*%$schema='

  -- Process documents in reverse order to maintain line numbers
  for i = #resource_schemas, 1, -1 do
    local resource_schema = resource_schemas[i]
    local start_line = resource_schema.start_line - 1 -- Convert to 0-indexed

    -- Check if modeline already exists at the start of this document
    local has_modeline = false
    if start_line < #lines then
      local line = lines[start_line + 1]
      if line and line:match(modeline_pattern) then
        has_modeline = true
        -- Update existing modeline
        vim.api.nvim_buf_set_lines(bufnr, start_line, start_line + 1, false, {
          '# yaml-language-server: $schema=' .. resource_schema.schema_url
        })
      end
    end

    -- Insert new modeline if it doesn't exist
    if not has_modeline then
      vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, {
        '# yaml-language-server: $schema=' .. resource_schema.schema_url
      })
    end
  end

  -- Clear flag after a short delay to allow the change to propagate
  vim.defer_fn(function()
    M.inserting_modelines[bufnr] = nil
  end, 100)
end

-- Refresh schemas for a buffer (called on buffer changes)
M.refresh_schemas = function(bufnr)
  local buffer_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local resource_schemas = {}

  -- Clear previous diagnostics for this buffer
  vim.diagnostic.reset(ns, bufnr)

  -- Extract all resources with their line numbers
  local resources = M.extract_api_version_and_kind(buffer_content)
  if not resources or #resources == 0 then
    return
  end

  local all_crds = M.list_github_tree()
  local unmatched = {}

  -- Match each resource to its schema
  for _, resource in ipairs(resources) do
    local schema_url = nil
    local description = nil

    -- First, try to match as a CRD
    local crd_name = M.normalize_crd_name(resource.api_version, resource.kind)
    if crd_name then
      for _, crd in ipairs(all_crds) do
        if crd:find(crd_name, 1, true) then
          local candidate_url = M.schema_url .. '/' .. crd
          local response = curl.get(candidate_url, { headers = M.config.github_headers })
          if response.status == 200 then
            schema_url = candidate_url
            description = resource.kind .. ' (' .. resource.api_version .. ')'
          end
          break
        end
      end
    end

    -- If not a CRD, try to match as a standard Kubernetes resource
    if not schema_url then
      local kubernetes_schema_url = M.get_kubernetes_schema_url(resource.api_version, resource.kind)
      if kubernetes_schema_url then
        schema_url = kubernetes_schema_url
        description = resource.kind .. ' (' .. resource.api_version .. ')'
      end
    end

    -- Add to resource_schemas if we found a schema, otherwise track as unmatched
    if schema_url then
      table.insert(resource_schemas, {
        start_line = resource.start_line,
        schema_url = schema_url,
        description = description,
      })
    else
      table.insert(unmatched, resource)
    end
  end

  -- Set diagnostics for resources with no schema found
  if #unmatched > 0 then
    local diagnostics = {}
    for _, resource in ipairs(unmatched) do
      table.insert(diagnostics, {
        lnum = resource.start_line - 1,
        col = 0,
        severity = vim.diagnostic.severity.WARN,
        message = 'No schema found for ' .. resource.kind .. ' (' .. resource.api_version .. ') — this resource is not validated',
        source = 'k8s-whisper',
      })
    end
    vim.diagnostic.set(ns, bufnr, diagnostics)
  end

  -- Insert modeline comments for each document
  if #resource_schemas > 0 then
    M.insert_schema_modelines(bufnr, resource_schemas)

    -- Show notification about attached schemas
    local descriptions = {}
    for _, rs in ipairs(resource_schemas) do
      table.insert(descriptions, rs.description)
    end
    if #descriptions == 1 then
      vim.notify('Attached schema: ' .. descriptions[1], vim.log.levels.INFO)
    else
      vim.notify('Attached ' .. #descriptions .. ' schemas: ' .. table.concat(descriptions, ', '), vim.log.levels.INFO)
    end
  end
end

-- Debounced refresh function
M.debounced_refresh = function(bufnr, delay)
  delay = delay or 1000 -- Default 1 second delay

  -- Don't refresh if we're currently inserting modelines
  if M.inserting_modelines[bufnr] then
    return
  end

  -- Cancel existing timer for this buffer
  if M.refresh_timers[bufnr] then
    vim.fn.timer_stop(M.refresh_timers[bufnr])
  end

  -- Create a new timer
  M.refresh_timers[bufnr] = vim.fn.timer_start(delay, function()
    -- Double-check we're not inserting modelines
    if not M.inserting_modelines[bufnr] then
      M.refresh_schemas(bufnr)
    end
    M.refresh_timers[bufnr] = nil
  end)
end

M.init = function(bufnr)
  -- Check if the schema has already been attached to this buffer
  if vim.b[bufnr].schema_attached then
    return
  end
  vim.b[bufnr].schema_attached = true -- Mark the schema as attached

  -- Initial schema attachment
  M.refresh_schemas(bufnr)

  -- Set up autocmds to refresh on buffer changes
  local augroup = vim.api.nvim_create_augroup('K8sWhisperRefresh_' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.debounced_refresh(bufnr)
    end,
  })

  -- Clean up when buffer is deleted
  vim.api.nvim_create_autocmd('BufDelete', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.clear_schemas(bufnr)
      vim.diagnostic.reset(ns, bufnr)
      if M.refresh_timers[bufnr] then
        vim.fn.timer_stop(M.refresh_timers[bufnr])
        M.refresh_timers[bufnr] = nil
      end
      M.inserting_modelines[bufnr] = nil
    end,
  })
end

return M
