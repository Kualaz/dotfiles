return {
	"Kualaz/pi-nvim",
	name = "pi-nvim",
	lazy = false,
	config = function()
		require("pi").setup()
	end,
}
