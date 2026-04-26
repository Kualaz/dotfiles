return {
	"NickvanDyke/opencode.nvim",
	enabled = false,
	dependencies = {
		{ "folke/snacks.nvim" },
	},
	config = function()
		---@type opencode.Opts
		vim.g.opencode_opts = {
			provider = {
				enabled = "wezterm",
				wezterm = {
					direction = "right", -- "left", "top", "right", "bottom"
					percent = 40, -- percentage of available space
				},
			},
		}

		-- Required for opts.events.reload
		vim.o.autoread = true

		-- Keymaps
		vim.keymap.set({ "n", "x" }, "<leader>aa", function()
			require("opencode").ask("@this: ", { submit = true })
		end, { desc = "Ask opencode" })

		vim.keymap.set({ "n", "x" }, "<leader>ax", function()
			require("opencode").select()
		end, { desc = "Execute opencode action…" })

		vim.keymap.set({ "n", "t" }, "<leader>ao", function()
			require("opencode").toggle()
		end, { desc = "Toggle opencode" })


	end,
}
