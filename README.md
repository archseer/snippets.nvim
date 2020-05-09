# snippets.nvim

LSP/TextMate snippet implementation based on Neovim's extmarks. Aiming to replace the need for UltiSnips and eventually upstreaming into neovim.

A continuation of [norcalli/nvim-snippets.lua](https://github.com/norcalli/nvim-snippets.lua).

## Why?

UltiSnips, vsnip and other implementations are larger because they need to calculate diffs and guess what exactly changed when the user edits snippet placeholders. With Neovim's extmarks, that problem is solved for us: we simply mark the start and end of each placeholder and the positioning will remain correct.

## Installation

Warning! This plugin is in development, expect things to be completely broken.

You need to compile neovim from source with [nvim_buf_set_text patches](https://github.com/neovim/neovim/pull/12249).

Install the plugin as usual, then add this to your config:

```lua
if vim.env.SNIPPETS then
  vim.snippet = require 'snippet'
end
```

Start neovim with the SNIPPETS env variable set:

```bash
SNIPPETS=1 nvim
```

For development, you can just clone the repository, then add the directory to your runtime path:
```
SNIPPETS=1 nvim -c "set rtp=."
```

## References

- https://github.com/microsoft/language-server-protocol/blob/master/snippetSyntax.md
- https://code.visualstudio.com/docs/editor/userdefinedsnippets
- https://github.com/microsoft/vscode/tree/master/src/vs/editor/contrib/snippet
- https://github.com/microsoft/vscode/tree/master/src/vs/workbench/contrib/snippets/browser

## Acknowledgements

- [hrsh7th/vim-vsnip](https://github.com/hrsh7th/vim-vsnip) for a good reference implementation in Vimscript.
- [norcalli/nvim-snippets.lua](https://github.com/norcalli/nvim-snippets.lua) for the original prototype this repository was based on.
