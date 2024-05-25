local utils = {}

utils.builtin_vars = require("snippets.utils.builtin")

---@type fun(path: string): string|nil
local function read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

---@type fun(filetype: string): boolean
function utils.is_filetype_ignored(filetype)
	local ignored_filetypes = Snippets.config.get_option("ignored_filetypes", {})
	return vim.tbl_contains(ignored_filetypes, filetype)
end

---@type fun(value: string|string[]): string[]
function utils.normalize_table(value)
	if type(value) == "table" then
		return value
	end

	local tbl = {}
	table.insert(tbl, value)
	return tbl
end

---@type fun(dir: string, result?: string[]): string[]
---@return string[]
function utils.scan_for_snippets(dir, result)
	result = result or {}

	local stat = vim.uv.fs_stat(dir)
	if not stat then
		return result
	end

	if stat.type == "directory" then
		local req = vim.uv.fs_scandir(dir)
		if not req then
			return result
		end

		local function iter()
			return vim.uv.fs_scandir_next(req)
		end

		for name, ftype in iter do
			local path = string.format("%s/%s", dir, name)

			if ftype == "directory" then
				result[name] = utils.scan_for_snippets(path, result[name] or {})
			else
				utils.scan_for_snippets(path, result)
			end
		end
	elseif stat.type == "file" then
		local name = vim.fn.fnamemodify(dir, ":t")

		if name:match("%.json$") then
			table.insert(result, dir)
		end
	elseif stat.type == "link" then
		local target = vim.uv.fs_readlink(dir)

		if target then
			utils.scan_for_snippets(target, result)
		end
	end

	return result
end

function utils.register_snippets()
	local search_paths = Snippets.config.get_option("search_paths", {})

	for _, path in ipairs(search_paths) do
		local files = utils.scan_for_snippets(path)
		for ft, file in pairs(files) do
			local key
			if type(ft) == "number" then
				key = vim.fn.fnamemodify(files[ft], ":t:r")
			else
				key = ft
			end

			if not key then
				return
			end

			Snippets.registry[key] = Snippets.registry[key] or {}
			if type(file) == "table" then
				vim.list_extend(Snippets.registry[key], file)
			else
				table.insert(Snippets.registry[key], file)
			end
		end
	end
end

---@type fun(path: string, silent?: boolean)
function utils.reload_file(path, silent)
	local contents = read_file(path)
	if contents then
		local reloaded_snippets = vim.json.decode(contents)
		Snippets.loaded_snippets = vim.tbl_deep_extend("force", {}, Snippets.loaded_snippets, reloaded_snippets)
		if not silent then
			vim.notify(string.format("Reloaded %d snippets", #vim.tbl_keys(reloaded_snippets), vim.log.levels.INFO))
		end
	end
end

---@type fun(filetype: string, files?: string[]): string[]
function utils.get_filetype(filetype, files)
	files = files or {}
	local ft_files = Snippets.registry[filetype]
	if type(ft_files) == "table" then
		for _, f in ipairs(ft_files) do
			table.insert(files, f)
		end
	else
		table.insert(files, ft_files)
	end
	return files
end

---@type fun(filetype: string): boolean
function utils.is_filetype_extended(filetype)
	if vim.tbl_contains(Snippets.config.get_option("extended_filetypes", {}), filetype) then
		return true
	end
	return false
end

---@type fun(filetype?: string): table<string, table>
function utils.get_snippets_for_ft(filetype)
	local loaded = {}
	local files = Snippets.registry[filetype]
	if not files then
		return loaded
	end

	if type(files) == "table" then
		for _, f in ipairs(files) do
			local contents = read_file(f)
			if contents then
				local snippets = vim.json.decode(contents)
				loaded = vim.tbl_deep_extend("force", {}, loaded, snippets) or loaded
			end
		end
	else
		local contents = read_file(files)
		if contents then
			local snippets = vim.json.decode(contents)
			loaded = vim.tbl_deep_extend("force", {}, loaded, snippets) or loaded
		end
	end
	return loaded
end

---@type fun(filetype: string, loaded?: table<string, table>): table<string, table>
function utils.get_extended_snippets(filetype, loaded)
	loaded = loaded or {}
	if not filetype then
		return loaded
	end

	local extended_snippets = Snippets.config.get_option("extended_filetypes", {})[filetype] or {}
	for _, ft in ipairs(extended_snippets) do
		if utils.is_filetype_extended(ft) then
			loaded = utils.get_extended_snippets(ft, loaded)
		else
			local snippets = utils.get_snippets_for_ft(ft)
			loaded = vim.tbl_deep_extend("force", {}, loaded, snippets)
		end
	end
	return loaded
end

---@type fun(loaded?: table<string, table>): table<string, table>
function utils.get_global_snippets(loaded)
	loaded = loaded or {}
	local global_snippets = Snippets.config.get_option("global_snippets", {})
	for _, ft in ipairs(global_snippets) do
		if utils.is_filetype_extended(ft) then
			loaded = utils.get_extended_snippets(ft, loaded)
		else
			local snippets = utils.get_snippets_for_ft(ft)
			loaded = vim.tbl_deep_extend("force", {}, loaded, snippets)
		end
	end
	return loaded
end

---@type fun(snippet: string): string
function utils.expand_vars(snippet)
	local lazy_vars = Snippets.utils.builtin_vars.lazy
	local eager_vars = Snippets.utils.builtin_vars.eager or {}

	local resolved_snippet = snippet
	local parsed_snippet = vim.lsp._snippet_grammar.parse(snippet)
	for _, child in ipairs(parsed_snippet.data.children) do
		local type, data = child.type, child.data
		if type == vim.lsp._snippet_grammar.NodeType.Variable then
			if eager_vars[data.name] then
				resolved_snippet = resolved_snippet:gsub("%$[{]?(" .. data.name .. ")[}]?", eager_vars[data.name])
			elseif lazy_vars[data.name] then
				resolved_snippet = resolved_snippet:gsub("%$[{]?(" .. data.name .. ")[}]?", lazy_vars[data.name]())
			end
		end
	end

	return resolved_snippet
end

---@type fun(prefix: string): table<string, table>|nil
function utils.find_snippet_prefix(prefix)
	if not prefix then
		return nil
	end

	local key = Snippets.prefix_lookup[prefix]
	return Snippets.loaded_snippets[key]
end

function utils.create_autocmd()
	if not Snippets.config.get_option("create_autocmd") then
		return
	end

	vim.api.nvim_create_autocmd("FileType", {
		group = vim.api.nvim_create_augroup("snippets_ft_detect", { clear = true }),
		pattern = "*",
		callback = function()
			Snippets.load_snippets_for_ft(vim.bo.filetype)
		end,
	})
end

function utils.register_cmp_source()
	require("snippets.utils.cmp").register()
end

function utils.load_friendly_snippets()
	local search_paths = Snippets.config.get_option("search_paths", {})
	for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
		if string.match(path, "friendly.snippets") then
			table.insert(search_paths, string.format("%s/snippets", path))
		end
	end
	Snippets.config.set_option("search_paths", search_paths)
end

return utils
