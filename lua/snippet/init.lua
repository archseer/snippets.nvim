--- Snippet mode.
--- @module snippet
--- @license MPL2.0

local vim = vim
local api = vim.api
local fn = vim.fn
local validate = vim.validate
local parse = require('snippet.parser').parse

local M = {}

--
-- @section Utilities
--

-- local function defaultdict(default_fn)
--   return setmetatable({}, {
--     __index = function(t, key)
--       local value = default_fn(key)
--       rawset(t, key, value)
--       return value
--     end;
--   })
-- end

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

local function clear_ns(bufnr, ns)
  return api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end


--- Stores currently active snippets.
-- {
--   [bufnr] = {
--     var_index = number;
--     vars = { [var_id] = { [] = { mark_start; mark_end; text(); range() } } }
--   }
-- }
local all_buffer_snippet_queues = defaultdict_table()

-- local apply_text_edits = vim.lsp.util.apply_text_edits
-- TODO: replace vim.lsp.apply_text_edits upstream once set_text is merged. No
-- more need for M.set_lines. Or any of these utils.
local set_lines = vim.lsp.util.set_lines
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

local function make_edit(y_0, x_0, y_1, x_1, text)
  return {
    range = {
      start = { line = y_0, character = x_0 };
      ["end"] = { line = y_1, character = x_1 };
    };
    newText = type(text) == 'table' and table.concat(text, '\n') or (text or "");
  }
end

--- nvim_win_get_cursor with 0-indexing
-- @tparam int bufnr
local function get_cursor()
  local pos = api.nvim_win_get_cursor(0)
  -- convert to 0-index line
  pos[1] = pos[1] - 1
  return pos
end

local function get_mark(bufnr, id)
  return api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, id)
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

local function select_region(A, B)
  -- convert lines to 1-indexed coordinates
  A[1] = A[1] + 1
  B[1] = B[1] + 1
  -- adjust  for off-by-1 when leaving insert mode
  A[2] = A[2] + 1
  B[2] = B[2] + 1

  -- api.nvim_feedkeys("\\<Esc>", 'ntx', true)
  fn.setpos("'<", {0, A[1], A[2]})
  fn.setpos("'>", {0, B[1], B[2]})
  api.nvim_input("gv<C-g>")
  -- api.nvim_command('call feedkeys("gv\\<C-g>", "ntx")')
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

--- Resolves common predefined TextMate/LSP variables into values.
-- See [VS Code documentation](https://code.visualstudio.com/docs/editor/userdefinedsnippets#_variables)
-- for more information.
--
-- @tparam string name
-- @treturn string value
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


--- Returns a function which can be used to append text at a pos or at the end
--- of the buffer.
local function updateable_buffer(bufnr, pos)
  validate { bufnr = {bufnr, 'n'} }
  local last_row, last_col
  if pos then
    pos = vim.list_extend({}, pos)
    last_row = pos[1]
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
      local last_line = lines[#lines] or ''
      if start_pos[1] == last_row then
        last_col = start_pos[2] + #last_line
      else
        last_col = #last_line
      end
      return start_pos, {last_row, last_col}
    end
  end
end

--- Highlights all occurrences of a variable.
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

--- Fetches the active snippet for buffer.
local function get_active_snippet(bufnr)
  local buffer_snippet_queue = all_buffer_snippet_queues[bufnr]
  return buffer_snippet_queue[#buffer_snippet_queue]
end

local function validate_snippet_body(body)
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

--- Mirror changes from one tabstop to all other matching tabstops
local function sync()
  local bufnr = resolve_bufnr(0)
  local active_snippet = get_active_snippet(bufnr)
  if not active_snippet then
    return false
  end

  local pos = get_cursor()
  -- offset by 1 to account for leaving insert/select mode
  pos[2] = pos[2] - 1

  clear_ns(bufnr, highlight_ns)
  local active_var = active_snippet.vars[active_snippet.var_index]
  -- highlight_variable(bufnr, active_var)

  -- Find the smallest matching var. Smallest because we want to edit the
  -- innermost tabstop: ${2: hello ${3:wor|ld}} <-- edit $3
  local match, new_text
  for var_id, vars in ipairs(active_snippet.vars) do
    for index, var in ipairs(vars) do
      local A, B = var.range()

      if A[1] <= pos[1] and B[1] >= pos[1] and A[2] <= pos[2] and B[2] >= pos[2] then
        text = var.text()
        if not match or #text < #new_text then
          match = var_id
          new_text = text
        end
      end
    end

  end

  -- not editing a variable
  if not match then
    return
  end

  local matches = active_snippet.vars[match]

  -- nothing to mirror
  if #matches == 1 then
    return
  end

  local edits = {}
  -- TODO: this callback still gets called for each edit then returns when the
  -- text doesn't match. Would be nice to skip triggering it, or doing so sooner.
  for _, var in ipairs(matches) do
    if var.text() ~= new_text then
      local A, B = var.range()
      local edit = make_edit(A[1], A[2], B[1], B[2]+1, new_text)
      table.insert(edits, edit)
    end
  end

  schedule(function()
    apply_text_edits(edits, bufnr)
  end)
end

---
--- @section Autocmd hooks
---

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

local function snippet_mode_setup()
  do_hook_autocmds {
    "autocmd TextChanged <buffer> lua vim.snippet._hooks.TextChanged()";
    "autocmd TextChangedI <buffer> lua vim.snippet._hooks.TextChanged()";
    "autocmd TextChangedP <buffer> lua vim.snippet._hooks.TextChanged()";
    -- "autocmd InsertCharPre <buffer> lua vim.snippet._hooks.InsertCharPre()";
    -- "autocmd InsertLeave <buffer> lua vim.snippet._hooks.InsertLeave()";
    -- "autocmd InsertEnter <buffer> lua vim.snippet._hooks.InsertEnter()";
  }
end

local function snippet_mode_teardown()
  do_hook_autocmds()
end

M._hooks = {}

function M._hooks.TextChanged()
  sync()
end

-- Built-in snippets
M.snippets = {
  ['loc'] = 'local ${1:var} = $CURRENT_YEAR $1 ${2:value}',
  -- TODO: handle $0 better. Should auto finish ($5).
  ['for'] = '${1:i} = ${2:1}, ${3:#lines} do\n  local v = ${4:t}[${1:i}]\nend\n$5',
}

---
--- @section Public API
---

--- Jump to the next/previous editable variable.
--
-- @tparam int direction Negative for jumping backwards.
-- @treturn bool If jump was successful.
function M.jump(direction)
  if direction ~= 0 then
    direction = direction / math.abs(direction)
  end
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
    local A, B = var[1].range()

    -- highlight_variable(bufnr, var)
    -- api.nvim_win_set_cursor(0, {B[1]+1, B[2]})

    -- TODO: be smart about it and select if range, insert/append if empty
    select_region(A, B)
    return true
  end
  return false
end

--- Expand `snippet` at current position in buffer.
--
-- @tparam table|string snippet The snippet to expand. Either string or parsed AST.
-- @treturn bool If expansion was successful.
function M.expand_snippet(snippet)
  local bufnr = resolve_bufnr(0)

  -- TODO: re-enable validate_snippet_body(snippet)

  -- TODO(ashkan) this should be changed when extranges are available.
  local var_mt = {
    __index = function(t, k)
      if k == 'range' then
        function t.range()
          local A = get_mark(bufnr, t.mark_start)
          local B = get_mark(bufnr, t.mark_end)
          -- convert to 1-indexing
          B[2] = B[2] - 1
          return A, B
        end
        return t.range
      elseif k == 'text' then
        function t.text()
          local A, B = t.range()
          local lines = api.nvim_buf_get_lines(bufnr, A[1], B[1]+1, false)
          if #lines == 1 then
            lines[1] = lines[1]:sub(A[2]+1, B[2]+1)
          else
            lines[1] = lines[1]:sub(A[2]+1)
            lines[#lines] = lines[#lines]:sub(1, B[2]+1)
          end
          -- TODO: keep separate?
          return table.concat(lines, '\n')
        end
        return t.text
      end
    end;
  }

  -- Create extmarks interspersed with regular text by using updateable_buffer
  local variable_map = defaultdict_table()
  local pos = get_cursor()
  local update = updateable_buffer(bufnr, pos)
  for _, node in ipairs(snippet) do
    local text
    if type(node) == 'string' then
      text = node
    elseif type(node) == 'table' then
      if node.type == 'tabstop' then
        -- TODO: initialize tabstop to prev value if any
        text = ' '
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

    local start_pos, end_pos = update(text)

    -- TODO: allow editing variables
    if type(node) == 'table' and node.type ~= 'variable' then
      -- we store positions then mark later, otherwise the ending mark would get
      -- pushed forward as we insert more text in the buffer.
      local var_id = assert(node.id)
      local var_part = {
        mark_start = start_pos;
        -- TODO(ashkan) this is only here until extranges exists.
        mark_end = end_pos;
      }
      -- TODO(ashkan) this is only here until extranges exists.
      var_part = setmetatable(var_part, var_mt)
      table.insert(variable_map[var_id], var_part)
    end
  end

  -- convert positions to marks
  for var_id, vars in ipairs(variable_map) do
    for index, var in ipairs(vars) do
      var.mark_start = api.nvim_buf_set_extmark(bufnr, mark_ns, 0, var.mark_start[1], var.mark_start[2], {right_gravity = false})
      var.mark_end = api.nvim_buf_set_extmark(bufnr, mark_ns, 0, var.mark_end[1], var.mark_end[2], {right_gravity = true})
    end
  end

  -- For fully resolved/static snippets, don't queue them.
  if not vim.tbl_isempty(variable_map) then
    table.insert(all_buffer_snippet_queues[bufnr], {
      var_index = 1;
      vars = variable_map;
    })
    snippet_mode_setup()
    M.jump(0)
  end

  -- TODO: append $0 past end if there's no $0 tabstop
end

--- Expand word at cursor into snippet.
--
-- @treturn bool If expansion was successful.
function M.expand_at_cursor()
  local pos = get_cursor()
  -- offset by 1 to account for leaving insert/select mode
  pos[2] = pos[2] + 1
  local offset = pos[2]
  local line = api.nvim_get_current_line()
  local word = line:sub(1, offset):match("%S+$")
  local snippet = M.snippets[word]
  if snippet then
    res, snippet, _ = parse(snippet, 1)
    if not res then
      return false
    end
    schedule(apply_text_edits, { make_edit(pos[1], pos[2] - #word, pos[1], pos[2], '') })
    schedule(M.expand_snippet, snippet)
    return true
  end
end

--- Finish editing the snippet. Tears down snippet mode.
--
-- @treturn table Snippet state.
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

---
--- @section Mappings
---

-- Need to use <Esc>:lua instead of <cmd>lua or will hit the bug where select mode will get entered twice, requiring two <Esc>s to leave
api.nvim_set_keymap("i", "<c-k>", "<Esc>:<C-u>lua return vim.snippet.expand_at_cursor() or vim.snippet.jump(1) or vim.snippet.finish_snippet()<CR>", {
  noremap = true;
  silent = true;
})

api.nvim_set_keymap("s", "<c-k>", "<Esc>:<C-u>lua return vim.snippet.expand_at_cursor() or vim.snippet.jump(1) or vim.snippet.finish_snippet()<CR>", {
  noremap = true;
  silent = true;
})

api.nvim_set_keymap("i", "<c-j>", "<Esc>:<C-u>lua vim.snippet.jump(-1)<CR>", {
  noremap = true;
  silent = true;
})

api.nvim_set_keymap("s", "<c-j>", "<Esc>:<C-u>lua vim.snippet.jump(-1)<CR>", {
  noremap = true;
  silent = true;
})

--- @export
return M
