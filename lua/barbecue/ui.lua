local navic = require("nvim-navic")
local devicons_ok, devicons = pcall(require, "nvim-web-devicons")
local config = require("barbecue.config")
local utils = require("barbecue.utils")
local Entry = require("barbecue.ui.entry")
local state = require("barbecue.ui.state")

local M = {}

---whether winbar is visible
---@type boolean
local visible = true

---returns dirname of `bufnr`
---@param bufnr number
---@return barbecue.Entry[]
local function get_dirname(bufnr)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local dirname = vim.fn.fnamemodify(filename, config.user.modifiers.dirname .. ":h")

  ---@type barbecue.Entry[]
  local entries = {}

  if dirname == "." then return {} end
  if dirname:sub(1, 1) == "/" then
    table.insert(
      entries,
      Entry.new({
        "/",
        highlight = "BarbecueDirname",
      })
    )
  end

  local protocol_start_index = dirname:find("://")
  if protocol_start_index ~= nil then
    local protocol = dirname:sub(1, protocol_start_index + 2)
    table.insert(
      entries,
      Entry.new({
        protocol,
        highlight = "BarbecueDirname",
      })
    )

    dirname = dirname:sub(protocol_start_index + 3)
  end

  local dirs = vim.split(dirname, "/", { trimempty = true })
  for _, dir in ipairs(dirs) do
    table.insert(
      entries,
      Entry.new({
        dir,
        highlight = "BarbecueDirname",
      })
    )
  end

  return entries
end

---returns basename of `bufnr`
---@param winnr number
---@param bufnr number
---@return barbecue.Entry|nil
local function get_basename(winnr, bufnr)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local basename = vim.fn.fnamemodify(filename, config.user.modifiers.basename .. ":t")
  if basename == "" then return nil end

  local text = {
    basename,
    highlight = "BarbecueBasename",
  }
  local icon
  if vim.bo[bufnr].modified and config.user.show_modified then
    icon = {
      config.user.symbols.modified,
      highlight = "BarbecueModified",
    }
  elseif devicons_ok then
    local ic, hl = devicons.get_icon_by_filetype(vim.bo[bufnr].filetype)
    if ic ~= nil and hl ~= nil then icon = { ic, highlight = hl } end
  end

  return Entry.new(text, icon, function(_, button)
    if button ~= "l" then return end

    vim.api.nvim_set_current_win(winnr)
    vim.api.nvim_win_set_cursor(winnr, { 1, 0 })
  end)
end

---returns context of `bufnr`
---@param winnr number
---@param bufnr number
---@return barbecue.Entry[]
local function get_context(winnr, bufnr)
  if not navic.is_available() then return {} end

  local nestings = navic.get_data(bufnr)
  if nestings == nil then return {} end

  return vim.tbl_map(function(nesting)
    local text = {
      nesting.name,
      highlight = "BarbecueContext",
    }
    local icon
    if config.user.kinds ~= false then
      icon = {
        config.user.kinds[nesting.type],
        highlight = "BarbecueContext" .. nesting.type,
      }
    end

    return Entry.new(text, icon, function(_, button)
      if button ~= "l" then return end

      vim.api.nvim_set_current_win(winnr)
      vim.api.nvim_win_set_cursor(winnr, { nesting.scope.start.line, nesting.scope.start.character })
    end)
  end, nestings)
end

---removes unused/previous callbacks in Entry class
---@param winnr number
local function remove_unused_callbacks(winnr)
  local ids = state.get_entry_ids(winnr)
  if ids ~= nil then
    for _, id in ipairs(ids) do
      Entry.remove_callback(id)
    end
  end
end

---truncates `entries` based on `max_length`
---@param entries barbecue.Entry[]
---@param length number
---@param max_length number
---@param basename_position number
local function truncate_entries(entries, length, max_length, basename_position)
  local ellipsis = Entry.new({
    config.user.symbols.ellipsis,
    highlight = "BarbecueEllipsis",
  })

  local has_ellipsis, i, n = false, 1, 0
  while i <= #entries do
    if length <= max_length then break end
    if n + i == basename_position then
      has_ellipsis = false
      i = i + 1
      goto continue
    end

    length = length - entries[i]:len()
    if has_ellipsis then
      if i < #entries then length = length - (utils.str_len(config.user.symbols.separator) + 2) end

      table.remove(entries, i)
      n = n + 1
    else
      length = length + utils.str_len(config.user.symbols.ellipsis)
      entries[i] = ellipsis

      has_ellipsis = true
      i = i + 1 -- manually increment i when not removing anything from entries
    end

    ::continue::
  end
end

---combines dirname, basename, and context entries
---@param winnr number
---@param bufnr number
---@param extra_length number
---@return barbecue.Entry[]
local function create_entries(winnr, bufnr, extra_length)
  local dirname = get_dirname(bufnr)
  local basename = get_basename(winnr, bufnr)
  local context = get_context(winnr, bufnr)
  if basename == nil then return {} end

  ---@type barbecue.Entry[]
  local entries = {}
  utils.tbl_merge(entries, dirname, { basename }, context)

  local length = extra_length
  for i, entry in ipairs(entries) do
    length = length + entry:len()
    if i < #entries then length = length + utils.str_len(config.user.symbols.separator) + 2 end
  end
  truncate_entries(entries, length, vim.api.nvim_win_get_width(winnr), #dirname + 1)

  return entries
end

---builds the winbar string from `entries` and `custom_section`
---@param entries barbecue.Entry[]
---@param custom_section string
---@return string
local function build_winbar(entries, custom_section)
  local winbar = "%#BarbecueNormal# "
  for i, entry in ipairs(entries) do
    winbar = winbar .. entry:to_string()
    if i < #entries then
      winbar = winbar
        .. "%#BarbecueNormal# %#BarbecueSeparator#"
        .. config.user.symbols.separator
        .. "%#BarbecueNormal# "
    end
  end

  return winbar .. "%#BarbecueNormal#%=" .. custom_section .. " "
end

---@async
---updates winbar on `winnr`
---@param winnr number?
function M.update(winnr)
  winnr = winnr or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winnr)

  if
    not vim.tbl_contains(config.user.include_buftypes, vim.bo[bufnr].buftype)
    or vim.tbl_contains(config.user.exclude_filetypes, vim.bo[bufnr].filetype)
    or vim.api.nvim_win_get_config(winnr).relative ~= ""
  then
    vim.wo[winnr].winbar = state.get_last_winbar(winnr)
    state.clear_state(winnr)

    return
  end

  if not visible then
    vim.wo[winnr].winbar = nil
    return
  end

  vim.schedule(function()
    if
      not vim.api.nvim_buf_is_valid(bufnr)
      or not vim.api.nvim_win_is_valid(winnr)
      or bufnr ~= vim.api.nvim_win_get_buf(winnr)
    then
      return
    end

    remove_unused_callbacks(winnr)
    local custom_section = config.user.custom_section(bufnr)
    local entries = create_entries(winnr, bufnr, 2 + utils.str_len(custom_section))
    if #entries == 0 then return end

    local winbar = build_winbar(entries, custom_section)
    state.save_state(winnr, entries)
    vim.wo[winnr].winbar = winbar
  end)
end

---toggles visibility
---@param shown boolean?
function M.toggle(shown)
  if shown == nil then shown = not visible end

  visible = shown
  for _, winnr in ipairs(vim.api.nvim_list_wins()) do
    M.update(winnr)
  end
end

return M
