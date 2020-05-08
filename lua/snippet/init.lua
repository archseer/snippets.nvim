local vim = vim
local api = vim.api
local fn = vim.fn
local validate = vim.validate
local parse = require('snippet.parser').parse

local M = {}

local function defaultdict(default_fn)
  return setmetatable({}, {
    __index = function(t, key)
      local value = default_fn(key)
      rawset(t, key, value)
      return value
    end;
  })
end

local function err_message(...)
  api.nvim_err_writeln(table.concat(vim.tbl_flatten{...}, ' '))
  api.nvim_command 'redraw'
end

local function resolve_bufnr(bufnr)
  if bufnr == 0 then
    return api.nvim_get_current_buf()
  end
  return bufnr
end

local function schedule(fn, ...)
  if select("#", ...) > 0 then
    return vim.schedule_wrap(fn)(...)
  end
  return vim.schedule(fn)
end

local defaultdict_table_mt = {__index=function(t,k) t[k] = {} return t[k] end}
local function defaultdict_table()
  return setmetatable({}, defaultdict_table_mt)
end

local mark_ns = api.nvim_create_namespace('snippet_marks')
local highlight_ns = api.nvim_create_namespace('snippet_var_highlight')

-- {
--   [bufnr] = {
--     var_index = number;
--     vars = { [var_id] = { [] = { mark_id; range() } } }
--   }
-- }
local all_buffer_snippet_queues = defaultdict_table()

local set_lines = vim.lsp.util.set_lines
-- local apply_text_edits = vim.lsp.util.apply_text_edits

-- TODO: these are from vim.lsp.apply_text_edits
local function sort_by_key(fn)
  return function(a,b)
    local ka, kb = fn(a), fn(b)
    assert(#ka == #kb)
    for i = 1, #ka do
      if ka[i] ~= kb[i] then
        return ka[i] < kb[i]
      end
    end
    -- every value must have been equal here, which means it's not less than.
    return false
  end
end
local edit_sort_key = sort_by_key(function(e)
  return {e.A[1], e.A[2], e.i}
end)
-- TODO: replace vim.lsp.apply_text_edits upstream once set_text is merged. No
-- more need for M.set_lines.
local function apply_text_edits(text_edits, bufnr)
  if not next(text_edits) then return end
  local start_line, finish_line = math.huge, -1
  local cleaned = {}
  for i, e in ipairs(text_edits) do
    start_line = math.min(e.range.start.line, start_line)
    finish_line = math.max(e.range["end"].line, finish_line)
    -- TODO(ashkan) sanity check ranges for overlap.
    table.insert(cleaned, {
      i = i;
      A = {e.range.start.line; e.range.start.character};
      B = {e.range["end"].line; e.range["end"].character};
      lines = vim.split(e.newText, '\n', true);
    })
  end

  -- Reverse sort the orders so we can apply them without interfering with
  -- eachother. Also add i as a sort key to mimic a stable sort.
  table.sort(cleaned, edit_sort_key)
  if not api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  local lines = api.nvim_buf_get_lines(bufnr, start_line, finish_line + 1, false)
  local fix_eol = api.nvim_buf_get_option(bufnr, 'fixeol')
  local set_eol = fix_eol and api.nvim_buf_line_count(bufnr) <= finish_line + 1
  if set_eol and #lines[#lines] ~= 0 then
    table.insert(lines, '')
  end

  for i = #cleaned, 1, -1 do
    local e = cleaned[i]
    api.nvim_buf_set_text(bufnr, e.A[1], e.A[2], e.B[1], e.B[2], e.lines)
  end
  -- TODO: port this
  -- if set_eol and #lines[#lines] == 0 then
  --   table.remove(lines)
  -- end
end

local function get_mark(bufnr, id)
  return api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, id)
end

local function make_edit(y_0, x_0, y_1, x_1, text)
  return {
    range = {
      start = { line = y_0, character = x_0 };
      ["end"] = { line = y_1, character = x_1 };
    };
    newText = type(text) == 'table' and table.concat(text, '\n') or (text or "");
  }
end

local function highlight_region(bufnr, ns, hlid, A, B)
  if A[1] == B[1] then
    api.nvim_buf_add_highlight(bufnr, ns, hlid, A[1], A[2], B[2])
  else
    api.nvim_buf_add_highlight(bufnr, ns, hlid, A[1], A[2], -1)
    api.nvim_buf_add_highlight(bufnr, ns, hlid, B[1], 0, B[2])
    for i = A[1] + 1, B[1] - 1 do
      api.nvim_buf_add_highlight(bufnr, ns, hlid, i, 0, -1)
    end
  end
end

-- local function find_max(t, score_fn)
--   if #t == 0 then return end
--   local max_i = 1
--   local max_score = score_fn(t[1])
--   for i = 2, #t do
--     local score = score_fn(t[i])
--     if max_score < score then
--       max_i, max_score = i, score
--     end
--   end
--   return max_i, max_score
-- end

local function clear_ns(bufnr, ns)
  return api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- Returns a function which can be used to append text at a pos or at the end
-- of the buffer.
local function updateable_buffer(bufnr, pos)
  vim.validate { bufnr = {bufnr, 'n'} }
  local last_row, last_col
  if pos then
    pos = vim.list_extend({}, pos)
    last_row = pos[1] - 1
    last_col = pos[2]
  else
    last_row = math.max(api.nvim_buf_line_count(bufnr) - 1, 0)
    local last_line = api.nvim_buf_get_lines(bufnr, last_row, 1, false)[1]
    last_col = #last_line or 0
  end
  return function(chunk)
    local lines = vim.split(chunk, '\n', true)
    if #lines > 0 then
      local start_pos = {last_row, last_col}
      -- nvim.print{lines = lines; last_line = last_line; last_line_idx = last_line_idx; start_pos=start_pos}
      api.nvim_buf_set_text(bufnr, last_row, last_col, last_row, last_col, lines)
      last_row = last_row + #lines - 1
      local last_line = lines[#lines]
      if start_pos[1] == last_row then
        last_col = start_pos[2] + #last_line or 0
      else
        last_col = #last_line or 0
      end
      return {last_row, last_col}, start_pos
    end
  end
end

local function highlight_variable(bufnr, var)
  clear_ns(bufnr, highlight_ns)
  for _, v in ipairs(var) do
    local A, B = v.range()
    -- TODO(ashkan) once extranges are in, we can highlight the whole region,
    -- but for now, bookkeeping the region end is cumbersome, so just highlight
    -- the first character?
    highlight_region(bufnr, highlight_ns, "Search", A, B)
  end
end

local function get_active_snippet(bufnr)
  local buffer_snippet_queue = all_buffer_snippet_queues[bufnr]
  return buffer_snippet_queue[#buffer_snippet_queue]
end

function M.validate_snippet_body(body)
  local var_ids = {}
  for _, v in ipairs(body) do
    if type(v) == 'table' then
      v[1] = var_ids[v.var_id] or v[1]
      validate {
        placeholder = {v[1], 's'};
        var_id = {v.var_id, 'n'};
      }
      var_ids[v.var_id] = var_ids[v.var_id] or v[1]
    else
      assert(type(v) == 'string')
    end
  end
  validate {
    snippet_ids = {var_ids, vim.tbl_islist, 'Snippet ids to be sequential'};
  }
end

local function nvim_commands(commands)
  for _, v in ipairs(vim.tbl_flatten(commands)) do
    api.nvim_command(v)
  end
end

local function do_hook_autocmds(inner)
  nvim_commands {
    "augroup SnippetsHooks";
    "autocmd!";
    inner or {};
    "augroup END";
  }
end

-- local all_buffer_save = defaultdict_table()

-- local function save_keymaps(bufnr)
--  local buffer_save = all_buffer_save[bufnr]
--  buffer_save.global_n = api.nvim_get_keymap('n')
--  buffer_save.buf_n = api.nvim_buf_get_keymap(bufnr, 'n')
-- end

-- local function restore_keymaps(bufnr)
--  local buffer_save = all_buffer_save[bufnr]
--  -- buffer_save.global_n = api.nvim_get_keymap('n')
--  -- buffer_save.buf_n = api.nvim_buf_get_keymap(bufnr, 'n')
-- end

local function snippet_mode_setup()
  do_hook_autocmds {
    "autocmd InsertCharPre <buffer> lua vim.snippet._hooks.InsertCharPre()";
    -- "autocmd InsertLeave <buffer> lua vim.snippet._hooks.InsertLeave()";
    -- "autocmd InsertEnter <buffer> lua vim.snippet._hooks.InsertEnter()";
  }
end

local function snippet_mode_teardown()
  do_hook_autocmds()
end

function M.finish_snippet()
  local bufnr = resolve_bufnr(0)
  local last_snip = table.remove(all_buffer_snippet_queues[bufnr])
  if vim.tbl_isempty(all_buffer_snippet_queues[bufnr]) then
    clear_ns(bufnr, highlight_ns)
    clear_ns(bufnr, mark_ns)
    snippet_mode_teardown()
  end
  return last_snip
end

function M.advance_snippet_variable(direction)
  if direction ~= 0 then
    direction = direction / math.abs(direction)
  end
--  assert(direction ~= 0)
--  direction = direction / math.abs(direction)
  local bufnr = resolve_bufnr(0)
  local active_snippet = get_active_snippet(bufnr)
  if not active_snippet then
    err_message("No active snippet")
    return
  end
  local new_index = active_snippet.var_index + direction
  local var = active_snippet.vars[new_index]
  if not vim.tbl_isempty(var or {}) then
    active_snippet.var_index = new_index
    highlight_variable(bufnr, var)
    local _, B = var[1].range()
    api.nvim_win_set_cursor(0, {B[1]+1, B[2]})
    return true
  end
  return false
end

-- function M.edit_active_variable()
--  local bufnr = resolve_bufnr(0)
--  local active_snippet = get_active_snippet(bufnr)
--  if not active_snippet then
--    err_message("No active snippet")
--    return
--  end
--  error("todo")
-- end

-- @see https://code.visualstudio.com/docs/editor/userdefinedsnippets#_variables
function resolve_variable(name)
  if name == 'TM_SELECTED_TEXT' then
    return '' -- TODO

  elseif name == 'TM_CURRENT_LINE' then
    return fn.getline('.')

  elseif name == 'TM_CURRENT_WORD' then
    return ''

  elseif name == 'TM_LINE_INDEX' then
    return fn.line('.') - 1

  elseif name == 'TM_LINE_NUMBER' then
    return fn.line('.')

  elseif name == 'TM_FILENAME' then
    return fn.expand('%:p:t')

  elseif name == 'TM_FILENAME_BASE' then
    return fn.substitute(fn.expand('%:p:t'), '^@<!..*$', '', '')

  elseif name == 'TM_DIRECTORY' then
    return fn.expand('%:p:h:t')

  elseif name == 'TM_FILEPATH' then
    return fn.expand('%:p')

  elseif name == 'CLIPBOARD' then
    return fn.getreg(vim.v.register)

  elseif name == 'WORKSPACE_NAME' then
    return ''

  elseif name == 'CURRENT_YEAR' then
    return fn.strftime('%Y')

  elseif name == 'CURRENT_YEAR_SHORT' then
    return fn.strftime('%y')

  elseif name == 'CURRENT_MONTH' then
    return fn.strftime('%m')

  elseif name == 'CURRENT_MONTH_NAME' then
    return fn.strftime('%B')

  elseif name == 'CURRENT_MONTH_NAME_SHORT' then
    return fn.strftime('%b')

  elseif name == 'CURRENT_DATE' then
    return fn.strftime('%d')

  elseif name == 'CURRENT_DAY_NAME' then
    return fn.strftime('%A')

  elseif name == 'CURRENT_DAY_NAME_SHORT' then
    return fn.strftime('%a')

  elseif name == 'CURRENT_HOUR' then
    return fn.strftime('%H')

  elseif name == 'CURRENT_MINUTE' then
    return fn.strftime('%M')

  elseif name == 'CURRENT_SECOND' then
    return fn.strftime('%S')

  elseif name == 'BLOCK_COMMENT_START' then
    return '/**' -- TODO

  elseif name == 'BLOCK_COMMENT_END' then
    return '*/' -- TODO

  elseif name == 'LINE_COMMENT' then
    return '//' -- TODO
  end

  return ''
end

function M.expand_snippet(snippet)
  local bufnr = resolve_bufnr(0)
  -- validate {
  --   body = {snippet.body, 't'};
  --   text = {snippet.text, 's', true};
  -- }
  -- TODO(ashkan) this should be changed when extranges are available.
  local var_mt = {
    __index = function(t, k)
      if k == 'range' then
        function t.range()
          local A = get_mark(bufnr, t.mark_start)
          local B = get_mark(bufnr, t.mark_end)
          A[2] = A[2] + 1
          B[2] = B[2] + 1
          return A, B
        end
        return t.range
      elseif k == 'text' then
        function t.text()
          local A, B = t.range()
          -- print(vim.inspect(A), vim.inspect(B))
          local lines = api.nvim_buf_get_lines(bufnr, A[1], B[1]+1, false)
          lines[1] = lines[1]:sub(A[2]+1)
          lines[#lines] = lines[#lines]:sub(1, B[2]+1)
          -- TODO: keep separate?
          return table.concat(lines, '\n')
        end
        return t.text
      end
    end;
  }
  -- TODO: re-enable M.validate_snippet_body(snippet)
  local pos = api.nvim_win_get_cursor(0)
  -- TODO(ashkan) make sure that only the first variable of each kind has text
  -- inserted for this basic version.

  -- Create extmarks interspersed with regular text by using updateable_buffer
  -- TODO: now embedding and refactoring this
  local variable_map = defaultdict_table()
  local update = updateable_buffer(bufnr, pos)
  for _, node in ipairs(snippet) do
    local text
    if type(node) == 'string' then
      text = node
    elseif type(node) == 'table' then
      if node.type == 'tabstop' then
        text = ''
      elseif node.type == 'placeholder' then
        -- TODO: handle recursive
        text = node.value[1]
      elseif node.type == 'choice' then
        -- TODO: open popup with choices
        text = node.value[1]
      elseif node.type == 'variable' then
        text = resolve_variable(node.name)
      end
    end

    local last_pos, start_pos = update(text)
    -- Disallow space characters. TODO(??)
    -- TODO: allow editing variables
    if type(node) == 'table' and node.type ~= 'variable' then
      -- we shift starting col one to the left, then return the correct val on range()
      -- otherwise set_text at this pos moves the marker to the right
      --
      -- TODO: start mark at 0,0, then inserting doesn't work properly, need
      -- left gravity. Ideally, insert left & right gravity marks at pos, then
      -- insert at that pos and it should just work.
      local mark_start = api.nvim_buf_set_extmark(bufnr, mark_ns, 0, start_pos[1], start_pos[2]-1, {})
      local mark_end = api.nvim_buf_set_extmark(bufnr, mark_ns, 0, last_pos[1], last_pos[2]-1, {})

      local var_id = assert(node.id)
      local var_part = {
        mark_start = mark_start;
        -- TODO(ashkan) this is only here until extranges exists.
        mark_end = mark_end;
      }
      -- TODO(ashkan) this is only here until extranges exists.
      var_part = setmetatable(var_part, var_mt)
      -- print(vim.inspect(var_part.text()))
      table.insert(variable_map[var_id], var_part)
    end
  end

  -- For fully resolved/static snippets, don't queue them.
  if not vim.tbl_isempty(variable_map) then
    table.insert(all_buffer_snippet_queues[bufnr], {
      var_index = 1;
      vars = variable_map;
    })
    -- TODO(ashkan) ignore placeholders for now. Those require making sure that
    -- users edit the mode with 'c' to start and stuff...
    snippet_mode_setup()
    M.advance_snippet_variable(0)
  end

  -- TODO: append $0 past end if there's no $0 tabstop
end

local function get_vim_key(s)
  return api.nvim_replace_termcodes(s, true, true, true)
end

local vim_keys = {
  bs = get_vim_key "<BS>";
  c_w = get_vim_key "<c-w>";
}

-- local function teardown_buffer(bufnr)
--  active_cursors[bufnr] = nil
--  all_buffer_cursors[bufnr] = nil
-- end

local function do_buffer(bufnr, fn)
  bufnr = resolve_bufnr(bufnr or 0)
  local active_snippet = get_active_snippet(bufnr)
  if not active_snippet then
    return false
  end
  local active_var = active_snippet.vars[active_snippet.var_index]
  local edits = {}
  local new_text = fn(active_var[1].text())
  for _, v in ipairs(active_var) do
    local A, B = v.range()
    local edit = make_edit(A[1], A[2], B[1], B[2], new_text)
    v.text = new_text
    table.insert(edits, edit)
  end
  if #edits > 0 then
    schedule(function()
      apply_text_edits(edits, bufnr)
      clear_ns(bufnr, highlight_ns)
      highlight_variable(bufnr, active_var)
      local A, B = active_var[1].range()
      api.nvim_win_set_cursor(0, {B[1]+1, B[2]})
    end)
    return true
  end
  return false
end

M._hooks = {}

function M._hooks.InsertCharPre()
  do_buffer(0, function(text)
    return text..vim.v.char
  end)
  vim.v.char = ''
end

-- function M._hooks.InsertLeave()
--  local bufnr = resolve_bufnr(0)
--  teardown_buffer(bufnr)
--  clear_ns(bufnr, hins)
--  clear_ns(bufnr, ns)
-- end

-- function M._hooks.InsertEnter()
--  local bufnr = resolve_bufnr(0)
--  local id = active_cursors[bufnr]
--  print(api.nvim_get_vvar('char'))
--  if id then
--    local B = assert(all_buffer_cursors[bufnr][id]).B
--    schedule(api.nvim_win_set_cursor, 0, {B[1]+1, B[2]})
--  end
-- end

function M._hooks.key_backspace()
  do_buffer(0, function(text)
    return text:sub(1, #text - 1)
  end)
  return vim_keys.bs
end

-- TODO(ashkan) set this up on expand snippet and restore the user settings
-- after finish_snippet
api.nvim_set_keymap("i", "<BS>", "v:lua.vim.snippet._hooks.key_backspace()", {
  expr = true;
})

M.snippets = {
  ['loc'] = 'local ${1:var} = $CURRENT_YEAR ${2:value}',
  -- TODO: handle $0 better. Should auto finish ($5).
  ['for'] = '${1:i} = ${2:1}, ${3:#lines} do\n  local v = ${4:t}[${1:i}]\nend\n$5',
}

function M.expand_at_cursor()
  local pos = api.nvim_win_get_cursor(0)
  local offset = pos[2]
  local line = api.nvim_get_current_line()
  local word = line:sub(1, offset):match("%S+$")
  local snippet = M.snippets[word]
  if snippet then
    res, snippet, _ = parse(snippet, 1)
    if not res then
      return false
    end
    pos[1] = pos[1] - 1
    schedule(apply_text_edits, { make_edit(pos[1], pos[2] - #word, pos[1], pos[2], '') })
    schedule(M.expand_snippet, snippet)
    return true
  end
end

api.nvim_set_keymap("i", "<BS>", "v:lua.vim.snippet._hooks.key_backspace()", {
  expr = true;
})

api.nvim_set_keymap("i", "<c-k>", "<cmd>lua return vim.snippet.expand_at_cursor() or vim.snippet.advance_snippet_variable(1) or vim.snippet.finish_snippet()<CR>", {
  noremap = true;
})

--api.nvim_set_keymap("i", "<c-z>", "<cmd>lua vim.snippet.expand_at_cursor()<CR>", {
--  noremap = true;
--})

-- api.nvim_set_keymap("i", "<c-k>", "<cmd>lua vim.snippet.advance_snippet_variable(1)<CR>", {
--  noremap = true;
-- })

api.nvim_set_keymap("i", "<c-j>", "<cmd>lua vim.snippet.advance_snippet_variable(-1)<CR>", {
  noremap = true;
})

--api.nvim_set_keymap("i", "<c-z>", "v:lua.vim.snippet.expand_at_cursor()", {
--  expr = true;
--})

return M
