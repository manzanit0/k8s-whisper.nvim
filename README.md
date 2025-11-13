# k8s-whisper.nvim

Autocomplete on k8s CRDs based on the schemas in
github.com/datreeio/CRDs-catalog. If no schema is available, it fallsback to
yamlls.

## 📦 Installation

Install the plugin with your package manager:

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "manzanit0/k8s-whisper.nvim",
  config = function()
    require('k8s-whisper').setup({
        -- This is a GitHub repository
        schemas_catalog = 'datreeio/CRDs-catalog',
        -- This is a git ref, branch, tag, sha, etc.
        schema_catalog_ref = 'main',
    })
  end
}
```

## TODO

- read https://zignar.net/2022/11/06/structuring-neovim-lua-plugins/
- Can it be configured as an LSP so that LSPStop works?

## Credit

Based on: https://www.reddit.com/r/neovim/comments/1iykmqc/improving_kubernetes_yaml_support_in_neovim_crds/
