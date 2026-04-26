return {
	"Kualaz/pi-nvim",
	name = "pi-nvim",
	lazy = false,
	config = function()
		local pi = require("pi")
		pi.setup()

		vim.keymap.set("n", "<leader>aa", function()
			pi.ask({ initial_text = "@this " })
		end, { desc = "Ask Pi (@this = current line)" })
		vim.keymap.set("x", "<leader>aa", function()
			pi.ask({ selection = pi.capture_selection(), initial_text = "@this " })
		end, { desc = "Ask Pi (@this = selection)" })
		vim.keymap.set("n", "<leader>ab", function()
			pi.send_all()
		end, { desc = "Ask Pi with buffer" })
		vim.keymap.set("n", "<leader>ap", function()
			pi.list_sessions()
		end, { desc = "Pick Pi session" })
	end,
}
