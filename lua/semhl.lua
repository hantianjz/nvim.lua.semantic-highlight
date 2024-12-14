local M = {}

local PLUGIN_NAME = "semhl"

M._HIGHLIGHT_CACHE = {}
M._WORD_CACHE = {}

function ts_diff(start_ts, end_ts)
  local sec = end_ts.sec - start_ts.sec
  local nsec = end_ts.nsec - start_ts.nsec
  if nsec < 0 then
    nsec = 1000000000 + nsec
    sec = sec - 1
  end
  pad = string.rep("0", 9 - string.len("" .. nsec))

  return sec .. "." .. pad .. nsec
end

local LOGGER = require("plenary.log").new({ plugin = PLUGIN_NAME, level = "debug", outfile="semhl.log", use_console = "sync" })

local function create_highlight(ns, rgb_hex)
  rgb_hex = rgb_hex:lower()
  local cache_key = table.concat({ "sfg", rgb_hex }, "_")
  local highlight_name = M._HIGHLIGHT_CACHE[cache_key]


  -- Look up in our cache.
  if highlight_name then
    local hl_id = vim.api.nvim_get_hl_id_by_name(highlight_name)
    if hl_id then
      return highlight_name
    end
  end

  -- Create the highlight
  highlight_name = table.concat({ "sfg", rgb_hex }, "_")
  vim.api.nvim_set_hl(ns, highlight_name, { fg = "#" .. rgb_hex })
  M._HIGHLIGHT_CACHE[cache_key] = highlight_name
  return highlight_name
end

local function recursive_child_iter(node, table_to_insert, desired_types)
  if node:iter_children() then
    for child in node:iter_children() do
      if desired_types then
        if vim.tbl_contains(desired_types, child:type()) then
          table.insert(table_to_insert, child)
        end
      else
        table.insert(table_to_insert, child)
      end

      recursive_child_iter(child, table_to_insert, desired_types)
    end
  end
end

local function get_nodes_in_array(buffer) --{{{
  local ts = vim.treesitter

  -- Yanked from https://github.com/nvim-treesitter/nvim-treesitter/blob/32e364ea3c99aafcce2ce735fe091618f623d889/lua/nvim-treesitter/parsers.lua#L4-L21
  local filetype_to_parsername = {
    proto = "c",
    arduino = "cpp",
    javascriptreact = "javascript",
    ecma = "javascript",
    jsx = "javascript",
    PKGBUILD = "bash",
    html_tags = "html",
    typescriptreact = "tsx",
    ["typescript.tsx"] = "tsx",
    terraform = "hcl",
    ["html.handlebars"] = "glimmer",
    systemverilog = "verilog",
    cls = "latex",
    sty = "latex",
    OpenFOAM = "foam",
    pandoc = "markdown",
    rmd = "markdown",
    cs = "c_sharp",
  }

  local ok, parser = pcall(ts.get_parser, buffer)
  if not ok then
    local cur_buf_filetype = vim.bo[buffer].ft
    parser = ts.get_parser(0, filetype_to_parsername[cur_buf_filetype])
  end

  if not parser then
    return nil
  end

  local trees = parser:parse()
  return trees[1]:root()
end --}}}

local function _on_text_change(buffer)
  LOGGER.debug("func: _on_text_change: " .. buffer);
end

local function _on_buffer_hide(buffer)
  LOGGER.debug("func: _on_buffer_hide: " .. buffer);
end

local function _new_on_buffer_enter(buffer)
  LOGGER.info("Buffer enter")
  local parser = vim.treesitter.get_parser(buffer, nil)

  local function on_tree_change(range, tree)
    LOGGER.info("on_tree_change")
    LOGGER.info(range)

    local children = {}
    recursive_child_iter(tree:root(), children, { "identifier", "type_identifier", "field_identifier" })

    for _, nn in ipairs(children) do
      local node_text = vim.treesitter.get_node_text(nn, buffer)
    end
  end

  parser:register_cbs({ on_changedtree = on_tree_change }, true)
end

local function _on_buffer_enter(buffer)
  LOGGER.debug("func: _on_buffer_enter: " .. buffer);
  -- require'plenary.profile'.start("semhl_profile.log")
  -- require'plenary.profile'.stop()

  local load_start_ts = vim.uv.clock_gettime("realtime")
  local root = get_nodes_in_array(buffer)
  if not root then
    return
  end

  vim.api.nvim_buf_clear_namespace(buffer, M._ns, 0, -1)

  local children = {}
  recursive_child_iter(root, children, { "identifier", "type_identifier", "field_identifier" })

  for _, nn in ipairs(children) do
    local node_text = vim.treesitter.get_node_text(nn, buffer)
    if node_text then
      local hlname = M._WORD_CACHE[node_text]
      if hlname == nil then
        local random_range = 1000;
        local hsv = { math.random(0, random_range) / random_range, math.random(0, random_range) / random_range, math
        .random(0, random_range) / random_range }
        local c = require("color_generator").color_generate(hsv[1], hsv[2], hsv[3])
        hlname = create_highlight(M._ns, string.sub(c, 2))
      end

      local srow, scol, erow, ecol = vim.treesitter.get_node_range(nn)

      -- Find NS for diag and make sure there isn't extmark exist for the same range already
      local diag_idx = next(vim.diagnostic.get_namespaces())
      local existing_extmark = nil
      if diag_idx then
        local diag_ns = vim.diagnostic.get_namespaces()[diag_idx].user_data.underline_ns
        if diag_ns then
          existing_extmark = vim.api.nvim_buf_get_extmarks(buffer, diag_ns, { srow, scol }, { erow, ecol }, {})
        end
      end

      if existing_extmark == nil or next(existing_extmark) == nil then
        vim.api.nvim_buf_add_highlight(buffer, M._ns, hlname, srow, scol, ecol)
      end


      M._WORD_CACHE[node_text] = hlname
    end
  end

  -- Activate the highlight
  vim.api.nvim_set_hl_ns(M._ns)

  local load_end_ts = vim.uv.clock_gettime("realtime")
  LOGGER.debug("load time: ", ts_diff(load_start_ts, load_end_ts))
end

local function _autoload(ev)
  LOGGER.debug("func: _autoload");
  local autocommands = vim.api.nvim_get_autocmds({
    group = M._semhl_augup,
    buffer = ev.buf,
    event = { "BufEnter" }
  })

  if autocommands == nil or next(autocommands) == nil then
    LOGGER.debug("!!!!Create autocommands for " .. ev.buf .. " !!!!")
    vim.api.nvim_create_autocmd(
      { "BufEnter" },
      { buffer = ev.buf, callback = function(env) _new_on_buffer_enter(env.buf) end, group = M._semhl_augup })
    -- vim.api.nvim_create_autocmd(
    --   { "BufHidden" },
    --   { buffer = ev.buf, callback = function(env) _on_buffer_hide(env.buf) end, group = M._semhl_augup })
    -- vim.api.nvim_create_autocmd(
    --   { "TextChanged", "TextChangedP" },
    --   { buffer = ev.buf, callback = function(env) _on_text_change(env.buf) end, group = M._semhl_augup })
  end

  -- TODO: Figure out how to add highlight incrementally
  -- vim.api.nvim_buf_attach(ev.buf, false, {
  --   on_lines = function(event_type, buf, changed_tick, firstline, lastline, new_lastline)
  --     vim.schedule(function()
  --       print(event_type, buf, changed_tick, firstline, lastline, new_lastline)
  --     end)
  --   end,
  --   on_detach = function()
  --   end,
  -- })
end

M.setup = function(filetypes)
  LOGGER.debug("func: setup");
  if M._init then
    return
  end

  vim.api.nvim_create_user_command("SemhlLoad", M.load, {})
  vim.api.nvim_create_user_command("SemhlUnload", M.unload, {})

  M._ns = vim.api.nvim_create_namespace(PLUGIN_NAME)
  M._semhl_augup = vim.api.nvim_create_augroup(PLUGIN_NAME, { clear = true })

  vim.api.nvim_create_autocmd({ "FileType" },
    { pattern = filetypes, callback = _autoload, group = M._semhl_augup })
  M._init = true
end

M.load = function()
  LOGGER.debug("func: load");
  local buffer = vim.api.nvim_get_current_buf()
  _autoload({ buf = buffer })
end

M.unload = function()
  LOGGER.debug("func: unload");
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buffer, M._ns, 0, -1)

  local autocommands = vim.api.nvim_get_autocmds({
    group = M._semhl_augup,
    buffer = buffer
  })

  for _, cmd in pairs(autocommands) do
    vim.api.nvim_del_autocmd(cmd.id)
  end
end

return M
