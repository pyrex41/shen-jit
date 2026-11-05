-- How the guide's code blocks and tables reach site/template.html. Pandoc has no grammar for Shen,
-- so this marks what the page colours itself: a transcript's prompts and output, and comments.

local function escape(text)
  return (text:gsub('[&<>]', { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;' }))
end

local function span(class, text)
  return '<span class="' .. class .. '">' .. escape(text) .. '</span>'
end

local function transcript(line)
  local prompt, rest = line:match('^(%(%d+[-+]%))(.*)$')
  if prompt then return span('p', prompt) .. escape(rest) end
  if line == '' then return '' end
  return span('o', line)
end

local function comments(pattern)
  return function(line)
    local code, comment = line:match('^(.-)(' .. pattern .. '.*)$')
    if code then return escape(code) .. span('c', comment) end
    return escape(line)
  end
end

local marks = {
  repl = transcript,
  sh = comments('%f[%S]#'),
  shen = comments('\\\\'),
}

function CodeBlock(block)
  local mark = marks[block.classes[1]] or escape
  local lines = {}
  for line in (block.text .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = mark(line)
  end
  return pandoc.RawBlock('html', '<pre><code>' .. table.concat(lines, '\n') .. '</code></pre>')
end

-- A wide table scrolls by itself, not the page.
function Table(wide)
  return pandoc.Div({ wide }, pandoc.Attr('', { 'wide' }))
end
