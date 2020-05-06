local vim = vim
local api = vim.api
local fn = vim.fn
local validate = vim.validate

local EXTMARKS = true

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
local apply_text_edits = vim.lsp.util.apply_text_edits

local function get_mark(bufnr, id)
  return api.nvim_buf_get_extmarks(bufnr, mark_ns, id, id, {limit=1})[1]
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

local function find_max(t, score_fn)
  if #t == 0 then return end
  local max_i = 1
  local max_score = score_fn(t[1])
  for i = 2, #t do
    local score = score_fn(t[i])
    if max_score < score then
      max_i, max_score = i, score
    end
  end
  return max_i, max_score
end

local function clear_ns(bufnr, ns)
  return api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- Returns a function which can be used to append text at a pos or at the end
-- of the buffer.
local function updateable_buffer(bufnr, pos)
  vim.validate { bufnr = {bufnr, 'n'}}
  local last_line, last_line_idx, final_suffix
  if pos then
    pos = vim.list_extend({}, pos)
    pos[1] = pos[1] - 1
    last_line = api.nvim_buf_get_lines(bufnr, pos[1], pos[1]+1, false)[1]
    final_suffix = last_line:sub(pos[2]+1)
    last_line = last_line:sub(1, pos[2])
    last_line_idx = pos[1]
  else
    last_line = api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
    last_line_idx = math.max(api.nvim_buf_line_count(bufnr) - 1, 0)
  end
  return function(chunk)
    local lines = vim.split(chunk, '\n', true)
    if #lines > 0 then
      lines[1] = last_line..lines[1]
      local start_pos = {last_line_idx, #last_line > 0 and #last_line or 0}
      last_line = lines[#lines]
      lines[#lines] = lines[#lines]..final_suffix
      -- nvim.print{lines = lines; last_line = last_line; last_line_idx = last_line_idx; start_pos=start_pos}
      api.nvim_buf_set_lines(bufnr, last_line_idx, last_line_idx + 1, false, lines)
      last_line_idx = last_line_idx + #lines - 1
      return {last_line_idx, #last_line > 0 and #last_line or 0}, start_pos
    end
  end
end

-- Create extmarks interspersed with regular text by using updateable_buffer
local function create_marked_buffer(bufnr, ns, data, pos)
  local update = updateable_buffer(bufnr, pos)
  local marks = {}
  for _, config in ipairs(data) do
    local text
    if type(config) == 'string' then
      text = config
    elseif type(config) == 'table' then
      text = config[1]
    end
    -- vim.validate{config={config,'t'}}
    local last_pos, start_pos = update(text)
    local mark_id
    -- Disallow space characters.
    if type(config) == 'table' then
      mark_id = api.nvim_buf_set_extmark(bufnr, ns, config.id or 0, start_pos[1], start_pos[2], {})
      -- local line = api.nvim_buf_get_lines(bufnr, start_pos[1], start_pos[1]+1, false)
--      mark_id = api.nvim_buf_set_extmark(bufnr, ns, config.id or 0, start_pos[1], math.max(0, math.min(start_pos[2], #line-1)), {})
    end
    table.insert(marks, {mark_id, start_pos, last_pos})
  end
  -- TODO(ashkan) this is for a bug where positions may be set incorrectly by
  -- the previous loop if multiple parts are on the same line, so we just
  -- reinforce the positions.
  for _, v in ipairs(marks) do
    if v[1] then
      api.nvim_buf_set_extmark(bufnr, ns, v[1], v[2][1], v[2][2], {})
    end
  end
  return marks
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

function M.expand_snippet(snippet)
  local bufnr = resolve_bufnr(0)
  validate {
    body = {snippet.body, 't'};
    text = {snippet.text, 's', true};
  }
  -- TODO(ashkan) this should be changed when extranges are available.
  local var_mt = {
    __index = function(t, k)
      if k == 'range' then
        function t.range()
          -- TODO(ashkan) @bfredl this is the part that breaks.
          local A
          if EXTMARKS then
            A = get_mark(bufnr, t.mark_id)
          else
            A = t.A
          end
          local lines = vim.split(t.text, '\n', true)
          local B = vim.list_extend({}, A)
          B[1] = B[1] + #lines - 1
          B[2] = B[2] + #lines[#lines]
          return A, B
        end
        return t.range
      end
    end;
  }
  local body = snippet.body
  M.validate_snippet_body(body)
  local pos = api.nvim_win_get_cursor(0)
  -- TODO(ashkan) make sure that only the first variable of each kind has text
  -- inserted for this basic version.
  local result = create_marked_buffer(bufnr, mark_ns, body, pos)
  local variable_map = defaultdict_table()
  -- Join the input definition with out output.
  for i, v in ipairs(result) do
    local mark_id = v[1]
    if mark_id then
      local config = body[i]
      assert(type(config) == 'table')
      local var_id = assert(config.var_id)
      local var_part = {
        mark_id = v[1];
        -- TODO(ashkan) this is only here until extranges exists.
        text = config[1];
      }
      if not EXTMARKS then
        var_part.A = v[2];
      end
      -- TODO(ashkan) this is only here until extranges exists.
      var_part = setmetatable(var_part, var_mt)
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
  local new_text = fn(active_var[1].text)
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
      local _, B = active_var[1].range()
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
  ['loc'] =  {
    body = {
      'local '; {'var', var_id = 1}; ' = '; {'value', var_id = 2};
    }
  };
  ['for'] =  {
    body = {
      'for '; {'i', var_id = 1}; ' = '; {'1', var_id = 2}; ', '; {'#lines', var_id = 3}; ' do\n';
      '  local v = '; {'t', var_id = 4}; '['; {'', var_id = 1}; '];\n';
      'end\n';
      -- TODO(ashkan) handle $0 better. Should auto finish.
      {'', var_id = 5};
    }
  };
}

function M.expand_at_cursor()
  local pos = api.nvim_win_get_cursor(0)
  local offset = pos[2]
  local line = api.nvim_get_current_line()
  local word = line:sub(1, offset):match("%S+$")
  local snippet = M.snippets[word]
  print(vim.inspect(word))
  if snippet then
    pos[1] = pos[1] - 1
    schedule(apply_text_edits, { make_edit(pos[1], pos[2] - #word, pos[1], pos[2], '') })
    schedule(M.expand_snippet, snippet)
    return true
  end
  return true
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
