-- bvnvim plugin loader
-- Loaded by Neovim at startup when bvnvim is in the runtimepath.
-- Defers to lua/bvnvim/init.lua for all logic.

-- Version guard: require Neovim 0.8+
if vim.fn.has("nvim-0.8") == 0 then
  vim.notify("bvnvim requires Neovim >= 0.8", vim.log.levels.ERROR)
  return
end

-- Expose public API
_G.BvNvim = require("bvnvim")
