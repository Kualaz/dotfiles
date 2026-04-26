return {
	"nvim-treesitter/nvim-treesitter",
	branch = "main",
	lazy = false,
	build = ":TSUpdate",
	config = function()
		local ts = require("nvim-treesitter")
		-- A list of parser names, or "all"
		ts.setup()
		ts.install({
			"vimdoc",
			"make",
			"javascript",
			"typescript",
			"markdown",
			"toml",
			"json",
			"html",
			"css",
			"c",
			"lua",
			"rust",
			"jsdoc",
			"bash",
			"c_sharp",
			"cpp",
			"go",
			"java",
			"php",
			"python",
			"query",
			"ruby",
			"terraform",
			"scala",
			"scss",
			"swift",
			"yaml",
		})

		-- Disable Vimscript Tree-sitter highlights. Lua's injection queries can
		-- parse vim.cmd strings as Vimscript, but the bundled Vimscript highlight
		-- query references node types that are not present in the active parser.
		vim.treesitter.query.set("vim", "highlights", "")

		local group = vim.api.nvim_create_augroup("kuala_treesitter", { clear = true })
		local indent_fts = {
			c = true,
			cs = true,
			javascript = true,
			lua = true,
			rust = true,
			sh = true,
			templ = true,
			typescript = true,
			go = true,
			c_sharp = true,
			terraform = true,
			make = true,
		}
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			pattern = "*",
			callback = function(args)
				if not pcall(vim.treesitter.start, args.buf) then
					return
				end
				if indent_fts[vim.bo[args.buf].filetype] then
					vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
				end
			end,
		})
	end,
}
-- G			sync_install = false,
--
-- 			-- Automatically install missing parsers when entering buffer
-- 			-- Recommendation: set to false if you don"t have `tree-sitter` CLI installed locally
-- 			auto_install = true,
--
-- 			indent = {
-- 				enable = true,
-- 			},
--
-- 			highlight = {
-- 				-- `false` will disable the whole extension
-- 				enable = true,
--
-- 				-- Setting this to true will run `:h syntax` and tree-sitter at the same time.
-- 				-- Set this to `true` if you depend on "syntax" being enabled (like for indentation).
-- 				-- Using this option may slow down your editor, and you may see some duplicate highlights.
-- 				-- Instead of true it can also be a list of languages
-- 				additional_vim_regex_highlighting = { "markdown" },
-- 			},
-- 		})
--
-- 		local treesitter_parser_config = require("nvim-treesitter.parsers").get_parser_configs()
-- 		treesitter_parser_config.templ = {
-- 			install_info = {
-- 				url = "https://github.com/vrischmann/tree-sitter-templ.git",
-- 				files = { "src/parser.c", "src/scanner.c" },
-- 				branch = "master",
-- 			},
-- 		}
--
-- 		vim.treesitter.language.register("templ", "templ")
-- 	end,
