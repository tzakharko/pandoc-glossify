-- pandoc-glossify
--
-- A pandoc filter for producing linguistic examples and interlinear  
-- glosses
-----------------------------
--
-- Copyright 2022 Taras Zakharko
-- 
--    Licensed under the Apache License, Version 2.0 (the "License");
--    you may not use this file except in compliance with the License.
--    You may obtain a copy of the License at
-- 
--        http://www.apache.org/licenses/LICENSE-2.0
-- 
--    Unless required by applicable law or agreed to in writing, software
--    distributed under the License is distributed on an "AS IS" BASIS,
--    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--    See the License for the specific language governing permissions and
--    limitations under the License.

local List = pandoc.List

-- list extensions
function List:new_with_fill(n, value)
  local list = List:new ()
  for i = 1, n do list[i] = value end
  return list
end

function List:any(predicate)
  for _, val in ipairs(self) do 
    if predicate(val) == true then return true end 
  end

  return false
end

function List:slice(i0, i1)
  if i1 == nil then i1 = #self end 
  local out = List:new {}
  for i = i0, i1 do out:insert(self[i]) end 
  return out
end


-- string extensions
function string:join(tab) 
  if not tab or #tab == 0 then 
    return "" 
  end
  local out = tostring(tab[1])
  for i, val in ipairs(tab) do
    if i > 1 then out = out .. self .. tostring(val) end
  end
  return out
end

-- immutable value emulation
do 
  local immutable_meta = {
    clone = function(self) 
      local out = {}
      for k, v in pairs(self) do out[k] = v end
      setmetatable(out, value_type_mt) 
    end,    
    __index = immutable_meta,
    __newindex = function (t,k,v)
      error("attempt to update an immutable value", 2)
    end    
  }

  function immutable(data) 
    setmetatable(data, immutable_meta)
    return data
  end
end



do
  -- example AST nodes
  local function InterlinearizedExample(glosses, header, footer, judgement)
    return immutable({
      type = "interlinearized_example",   
      glosses = glosses,
      judgement = judgement or "",
      header = header,
      footer = footer
    })
  end

  local function PlainExample(text, header, footer, judgement)
    return immutable({
      type = "plain_example",   
      text = text,
      judgement = judgement or "",
      header = header,
      footer = footer
    })
  end

  local P = lpeg.P
  local R = lpeg.R
  local S = lpeg.S
  local B = lpeg.B
  local V = lpeg.V

  local C = lpeg.C
  local Cg = lpeg.Cg
  local Ct = lpeg.Ct
  local Cc = lpeg.Cc
  local Cp = lpeg.Cp
  local Cb = lpeg.Cb
  local Cmt = lpeg.Cmt
  local Cg_init = function(name, value) return Cg(Cc(value), name) end

  -- basic matchers
  local eol = P"\n\r" + P"\r\n" + P"\n" + P"\r" 
  local whitespace = S" \t\v"
  local whitespaces = whitespace^1
  local content = (1 - eol)^0 - (whitespace^0*eol)
  local empty_lines = (whitespace^0 * eol)^0

  

    -- token line parsing and alignment
  local open_brace = P"{" - B"\\"
  local close_brace = P"}" - B"\\"
  local gr_judgement = (whitespace^0)*C((S "*?#")^-1)*(whitespace^0)
  local capture_glyph_offset = Cmt(P "", function(text, pos) 
    -- add one to the length at the string end to make sure that token end
    -- always exceeds token start
    local offset = (pos > #text) and 1 or 0

    return true, pandoc.layout.real_length(text:sub(1, pos)) + offset
  end)

  local tokens_grammar = P {
    "tokens";
    tokens = (((whitespace^0) * (V "token"))^0)/function(...) 
      return List:new {...} 
    end,
    token = 
        -- start
        capture_glyph_offset *   
        -- token text
        (V "group_token" + C(V "simple_token")) *
        -- end
        capture_glyph_offset,
    simple_token = (1 - whitespace)^1,
    group_token  = (
      open_brace*
      C(((1-(open_brace + close_brace)) + V "group_token")^0)*
      (close_brace + (-1)) -- it's ok if the line ends and the group is not closed!
    )
  }

  local function match_judgement(text)
    local judgement, pos = lpeg.match(gr_judgement*Cp(), text)
    return judgement or "", pos or 1
  end

  local function tokenize_line(text, include_judgement)
    -- grammaticality judgement
    local judgement, pos = nil, 1
    if include_judgement == true then 
      judgement, pos = match_judgement(text)
    end
    -- tokens proper
    local tokens = lpeg.match(tokens_grammar, text, pos)
    return tokens, judgement
  end

  local function align_tokenized_lines(tokenized_lines)
    local inf = math.huge
    local n_lines = #tokenized_lines

    -- make a list of scanline intersetions and sort them
    -- (line, position, start|end)
    local events = List:new {}
    for line, tokens in ipairs(tokenized_lines) do 
      for i = 1, #tokens, 3  do 
        events:insert({ line, tokens[i], 0 })
        events:insert({ line, tokens[i+2], 1 })
      end 
    end

    events:sort(function(e1, e2)
      -- sort by position, when there is a tie, take token end first
      return (e1[2] < e2[2]) or (e1[2] == e2[2] and (e1[3] > e2[3] or e1[1] < e2[1]))
    end)


    -- alignment state
    local last_token = List:new_with_fill(n_lines, 0)
    local column_start = 0
    local column = List:new_with_fill(n_lines, -1)
    local n_open  = 0

    local columns = List:new()

    -- process the events
    for _, event in ipairs(events) do 
      local line, pos, event = table.unpack(event)

      -- a token start
      if event == 0 then 
        -- first token of a column
        if n_open == 0 then column_start = pos end 
          
        n_open = n_open + 1
        column[line] = last_token[line] + 1

        -- we have alignment violation if the start does not align
        if pos ~= column_start then 
          return nil, nil, pos
        end
      else 
      -- a token end
        assert(column[line] == last_token[line] + 1, "token closed without being opened")

        -- close the token and flush the column if no tokens are open
        last_token[line] = last_token[line] + 1

        n_open = n_open - 1
        if n_open == 0 then 
          for i=1,n_lines do 
            if column[i] > 0 then 
              column[i] = tokenized_lines[i][column[i]*3 - 1]
            else
              column[i] = ""
            end
          end
          columns:insert(column)
          column = List:new_with_fill(n_lines, -1)
        end
      end
    end

    -- if the first line only has a single token and the other lines have more 
    -- tokens then we don't consider this aligned
    if last_token[1] == 1 and #columns > 1 then 
      return nil, nil, tokenized_lines[1][2]
    end

    return columns, last_token
  end

  -- first chracter is an opening quotation mark
  local open_quote = whitespace^0*(S "`'\"" + P "«" + P "‘" + P "‛" + P "“" + P "‟" + P "‹")

  local function is_translation_line(text)
    return lpeg.match(open_quote, text) ~= nil
  end

  local function parse_interlinear_gloss(lines, allow_header_line)
    -- the first line is either the header line or the transcription
    local tokenized_lines, judgement = tokenize_line(lines[1], true)

    tokenized_lines = List:new {tokenized_lines}
    local first_gloss_line = 1
    local last_gloss_line = 1
    local aligned_tokens = nil

    -- progressively align more lines until we have a failure
    for i= 2, #lines do 
      local line = lines[i]

      -- stop aligning if a translation is detected
      if is_translation_line(line) then break end 

      -- try to align the next line
      local tokens = tokenize_line(line, false)
      tokenized_lines:insert(tokens)

      aligned_tokens = align_tokenized_lines(tokenized_lines)

      -- alignment failure
      if aligned_tokens == nil then 
        -- retry aligning skipping the first line
        if allow_header_line == true and i == 2 then 
          first_gloss_line = 2
          tokens, judgement = tokenize_line(line, true)
          tokenized_lines = List:new {tokens}
        else 
          -- stop aligning
          break
        end 
      end 

      -- update the last aligned line
      last_gloss_line = i
    end

    -- return nothign if no gloss has been detected
    if aligned_tokens == nil then return nil end

    local header, footer = nil, nil

    -- header and footer
   
    if first_gloss_line > 1 then header = lines:slice(1, first_gloss_line - 1) end 
    if last_gloss_line < #lines then footer = lines:slice(last_gloss_line + 1) end 

    return aligned_tokens, header, footer, judgement
  end

  -- we expect there to be one, two or three paragraphs
  -- any excess paragraphs are left as is
  --
  -- the example proper is either the first paragraph or the first paragraph
  -- is the header and the example proper is then the second paragraph
  --
  -- we proceeed in the following fashion:
  --
  -- 1. we check if the second or first paragraph can be parsed as an 
  --    interlinear gloss
  -- 2. if neither can, we assume that this is a plain example and take 
  --    the second paragraph (if it exists)
  -- 3. otherwise we assemble the interlienar gloss by using the preceding 
  --    paragraph (if any) as a header and the following paragraph (if no 
  --    inline footer is detected) as a footer
  local function detect_examples(items)
    if #items == 0  then return items end
    
    -- detect examples in the internal blocks
    local has_subexamples = false
    for _, v in ipairs(items) do 
      if v.type == "block" then 
        v.items = detect_examples(v.items)
        has_subexamples = true
      else
        if v.type ~= "text" then error("text item expected!") end
      end
    end

    if has_subexamples then return items end

    -- try to locate the paragraph with the interlinear gloss
    local example_idx = math.min(#items, 2)
    local header, footer, body, judgement = nil, nil, nil, nil

    while example_idx > 0 do 
      -- try to parse the gloss paragraph
      body, header, footer, judgement = parse_interlinear_gloss(items[example_idx].lines, example_idx == 1)
    
      -- exit on success, otherwise try the previous paragraph
      if body ~= nil then break end 
      example_idx = example_idx - 1
    end

    -- if we were not able to parse an interlinear gloss body then this must be a plain example
    local example_ctr = nil
    if body == nil then
      example_idx = math.min(#items, 2)
      example_ctr = PlainExample
      body = items[example_idx].lines
      
      -- if there is a translation line that will be the footer
      for i = 2, #body do 
        if is_translation_line(body[i]) then 
          footer = body:slice(i)
          body = body:slice(1, i - 1)
        end
      end

      -- detect the grammaticality judgement
      local pos = 1
      judgement, pos = match_judgement(body[1])
      body[1] = body[1]:sub(pos)
    else 
      example_ctr = InterlinearizedExample
    end

    -- number of paragraphs processed
    local n_processed = example_idx

    -- header and footer
    if example_idx == 2 then 
      assert(header == nil)
      header = items[1].lines
    end       
    if footer == nil and (#items > example_idx) then 
      footer = items[example_idx + 1].lines
      n_processed = example_idx + 1
    end

    -- assemble the output
    local out = List:new { example_ctr(body, header, footer, judgement) }

    if n_processed < #items then 
      out:extend(items:slice(n_processed + 1))
    end

    return out
  end


  -- LPEG grammar for parsing an example block
  local example_block_grammar = P {
    "block";
    -- example is a sequence of paragraphs and (optionally) nested subexamples
    block = (
      Cg_init("indent", -1) * 
      Cg_init("is_first", false) * 
      (empty_lines * (V "subexample" + V "paragraph"))^0
    )/function(...) 
      return { type = "block", level = 0, items = List:new { ... } }
    end,
    -- paragraph, a sequence of (maybe indented) lines
    paragraph = (
      (V "indented_line") * 
      Cg_init("is_first", false) * 
      (V "indented_line")^0
    )/function(...) 
      return {type = "text", lines = List:new { ... } }
    end,
    -- indented block, a sequence of indented paragraphs
    indented_block = (
      -- continue parsing the first line of the block
      Cg_init("is_first", true) *
      ((V "paragraph") + empty_lines) *
      -- parse the other paragraphs in the block
      Cg_init("is_first", false) *
      (empty_lines * (V "paragraph"))^0
    ),
    -- subexample header
    subexample_indicator = (
      -- letter + dot
      (R "az" * P ".") +
      -- number + dot
      (R "09" * P ".") +
      -- a list 
      (P "-")
    ),
    subexample_header = (
      -- letter + dot (save as block indent)
      Cg(C(whitespace^0 * (V "subexample_indicator") * #(whitespace + eol)), "indent") *
      -- extract the letter
      (Cb("indent")/function(x) return x:sub(-2, -2) end) * 
      -- compute the block indentation
      Cg(Cb("indent")/function(x) return #x end, "indent")
    ),
    -- subexample is a header + indented block
    subexample = (
      (V "subexample_header") *
      (V "indented_block") 
    )/function(letter, ...) 
      return { type = "block", level = 1, letter = letter, items = List:new { ... } }
    end,
    -- indented line, 'indent' is used to track block indent, 'is_first' is 
    -- used to check if this is the part of first line after the indented block header
    indented_line = Cmt(C(content)*(Cb "indent")*(Cb "is_first")*eol, function(_, _, text, indent, is_first)
      -- first line gets indented 
      if is_first then 
        return true, string.rep(" ", indent) .. text 
      end

      -- check if the line is indented 
      local _, ii = text:find("%s*")
      return ii > indent, text
    end)
  }

  function parse_example(text)
    -- note: add a trailing line break to make PEG parsing easier
    local parsed_block = lpeg.match(example_block_grammar, text .. "\n")  
    parsed_block.items = detect_examples(parsed_block.items)
    return parsed_block
  end  
end

-- gloss component iterator
do
  local P = lpeg.P
  local R = lpeg.R
  local Cmt = lpeg.Cmt
  local C = lpeg.C
  local Cc = lpeg.Cc
  local Cp = lpeg.Cp

  local gloss_token = Cmt(C((R "AZ" + R "09")^1), function(_, _, text)
    return true
  end)

  local other_token = (P(1) - gloss_token)^1

  local token = (C(gloss_token)*Cc("gloss") + C(other_token)*Cc("other"))*Cp()

  function gloss_iterator(state)
    local token, type, pos = lpeg.match(token, state.text, state.pos)
    if token == nil then return nil end

    state.pos = pos
    return token, type
  end

  function iterate_glosses(text)
    return gloss_iterator, {text = text, pos = 1}
  end
end

-- markdown rendering
do
  -- we maintain a list of extra citations to be added from the paragraphs
  local nocite_list = List:new {}
  local metadata_copy = nil

  function setup_metadata_copy(meta)  
    -- clone the metadata for the local citeproc application
    local meta_clone = {}
    for k, v in pairs(meta) do 
      meta_clone[k] = v
    end

    metadata_copy = pandoc.Meta(meta_clone)
    metadata_copy["suppress-bibliography"] = pandoc.MetaBool(true)
  end  


  function parse_markdown_inlines(text)
    assert(pandoc.utils.type(text) == "List")

    -- parse the markdown to a pandoc document
    local doc = pandoc.read(("\n"):join(text), "markdown", PANDOC_READER_OPTIONS)

    -- collect the citations to add them to the nocite list
    local any_citations = false
    doc:walk({Cite = function(elt) 
      nocite_list:insert(elt) 
      any_citations = true
    end})
  
    -- run citeproc on the document (suppressing bibliography generation)
    if any_citations then 
      doc.meta = metadata_copy
      doc = pandoc.utils.citeproc(doc)
    end

    -- flatten the document to a list of inlines
    return pandoc.utils.blocks_to_inlines(doc.blocks)
  end

  function add_internal_citations(meta)
    if #nocite_list > 0 then 
      local nocite_inlines = List:new()
      for i, elt in ipairs(nocite_list) do 
        if i > 1 then 
          nocite_inlines:insert(pandoc.Str(","))
          nocite_inlines:insert(pandoc.Space())
        end
        nocite_inlines:insert(elt)
      end
      if meta.nocite ~= nil and pandoc.utils.type(meta.nocite) == "Blocks" then 
        meta.nocite:insert(pandoc.Para(pandoc.Inlines(nocite_inlines)))
      else
        meta.nocite = pandoc.MetaBlocks(pandoc.Para(pandoc.Inlines(nocite_inlines)))  
      end
    end

    return meta
  end
end



-- DOCX support
do
  local gloss_cell_width = 20
  local full_table_width = 8000


  local stringify = pandoc.utils.stringify
  local RawInline = pandoc.RawInline
  local pandoc_type = pandoc.utils.type
  local glyph_width = pandoc.layout.real_length


  -- text formatting
  local function par(content, props)
    if props == nil then props = "" end
    if props ~= "" then 
      props = "<w:pPr>" .. props .. "</w:pPr>"
    end

    return "<w:p>" .. props .. content .. "</w:p>"
  end

  local function textrun(text, props)
    if text == nil then text = "" end
    if props == nil then props = "" end
    if props ~= "" then 
      props = "<w:rPr>" .. props .. "</w:rPr>"
    end

    return "<w:r>" .. props .. "<w:t>" .. text .. "</w:t></w:r>"
  end

  local function render_inlines(inlines, props)
    assert(pandoc_type(inlines) == "Inlines")
    if props == nil then props = "" end

    local out = ""
    for _, elt in ipairs(inlines) do 
      local t = elt.tag
      local raw
      if t == "Str" then 
        raw = textrun(elt.text, props)
      elseif t == "Emph" then 
        raw = render_inlines(elt.content, props .. "<w:i/>")        
      elseif t == "Strong" then 
        raw = render_inlines(elt.content, props .."<w:b/>")        
      elseif t == "SmallCaps" then 
        raw = render_inlines(elt.content, props .. "<w:smallCaps w:val=\"true\"/>")        
      elseif t == "RawInline" and elt.format == "openxml" then 
        raw = elt.text
      elseif t == "Space" then 
        raw = "<w:r><w:t xml:space=\"preserve\"> </w:t></w:r>"
      elseif t == "LineBreak" then   
        raw = "<w:r><w:br/></w:r>"
      else 
        local content = elt.content
        if content ~= nil and pandoc_type(content) == "Inlines" then 
          raw = render_inlines(content, props)
        else 
          raw = textrun(stringify(elt), props)
        end
      end

      out = out .. raw
    end 

    return out
  end  

  -- table formatting
  local tbl_no_border_spec = [[<w:tblBorders><w:top w:val="none" w:sz="0"/><w:start w:val="none" w:sz="0"/><w:bottom w:val="none" w:sz="0"/><w:end w:val="none" w:sz="0"/><w:insideH w:val="none" w:sz="0"/><w:insideV w:val="none" w:sz="0"/></w:tblBorders>]]

  local table_props = [[
    <w:tblPr>
    <w:tblW w:w="%s" w:type="dxa"/>
    <w:tblLayout w:type="fixed"/>
    <w:tblBorders>
      <w:top w:val="none" w:sz="0"/>
      <w:start w:val="none" w:sz="0"/>
      <w:bottom w:val="none" w:sz="0"/>
      <w:end w:val="none" w:sz="0"/>
      <w:insideH w:val="none" w:sz="0"/>
      <w:insideV w:val="none" w:sz="0"/>
    </w:tblBorders>
    <w:tblCellMar>
      <w:top w:w="0" w:type="dxa"/>
      <w:start w:w="0" w:type="dxa"/>
      <w:bottom w:w="0" w:type="dxa"/>
      <w:end w:w="0" w:type="dxa"/>
    </w:tblCellMar>   
    </w:tblPr>
  ]]
  table_props = string.format(table_props, full_table_width)

  local function tbl_cell(content, n_cells, props)
    if n_cells == nil then n_cells = 1 end
    if props == nil then props = "" end
    if n_cells > 1 then 
      props = props .. "<w:gridSpan w:val=\"" .. n_cells .. "\"/>"  
    end
    props = "<w:tcPr>" .. props .. tbl_no_border_spec .. "</w:tcPr>"

    return "<w:tc>" .. props .. content .. "</w:tc>"
  end

  local function tbl_col_spec(width) 
    return "<w:gridCol w:w=\"" .. width .. "\"/>"
  end  


  local function render_gloss_cell(glosses)
    if #glosses == 0 then return "" end

    local out = textrun(glosses[1], "<w:i/>")
    for i = 2, #glosses do 
      out = out .. "<w:r><w:br/></w:r>" 
      for token, type in iterate_glosses(glosses[i]) do 
        local prop = ""
        if type == "gloss" then 
          token = token:lower()
          prop = "<w:smallCaps w:val=\"true\"/>"
        end
        out = out .. textrun(token, prop)
      end
    end

    return par(out, "<w:jc w:val=\"left\"/>")
  end

  -- table cell layout

  -- text width estimation in dxa (1 dxa = 1/20pt)
  -- TODO: provide ways to tweak these setting. For now we assume that 1 letter is 6pt
  local function estimate_dxa_width_for_text(text)
    local n = glyph_width(text)
    return math.ceil((n+1)*8*20)
  end

  local function estimate_dx_width_for_glosses(glosses)
    local w = 200
    for _, gloss in ipairs(glosses) do 
      w = math.max(w, estimate_dxa_width_for_text(gloss)) 
    end
    return w + 40
  end

  -- return the number of cells required to fit contents of the given width
  local function allocate_cells(width, start, cell_widths)
    local w = cell_widths[start]
    local i = start + 1
    while w < width and i <= #cell_widths do 
      w = w + cell_widths[i]
      i = i + 1
    end

    
    if w < width then 
      -- note: we allow for row overflow if the gloss is extremely wide
      --       and we are just starting
      if (start == 1) then return #cell_widths else return nil end 
    else 
      return i - start 
    end
  end

  local function render_gloss_rows(glosses, cell_widths)
    local rows = List:new {}
    local row = ""
    local next_cell = 1
    local gloss_idx = 1

    while gloss_idx <= #glosses do 
      local gloss = glosses[gloss_idx]

      -- try to fit the cell
      local n_cells = allocate_cells(estimate_dx_width_for_glosses(gloss), next_cell, cell_widths)

      -- if the gloss fits in the row, we add it
      if n_cells ~= nil then 
        row = row .. tbl_cell(render_gloss_cell(gloss), n_cells)
        next_cell = next_cell + n_cells
        gloss_idx = gloss_idx + 1
      end

      -- do we need to commit the row?
      if n_cells == nil or next_cell > #cell_widths then 
        local remaining_cells = #cell_widths - next_cell
        if remaining_cells > 0 then row = row .. tbl_cell(par(textrun("")), remaining_cells) end
        rows:insert(row)
        next_cell = 1
        row = ""
      end
    end

    -- commit the last row
    if row ~= "" then 
      local remaining_cells = #cell_widths - next_cell
      if remaining_cells > 0 then row = row .. tbl_cell(par(textrun("")), remaining_cells) end
      -- push the row
      rows:insert(row)
    end

    return rows
  end  

  local function add_label_column(rows, label, cell_widths)
    if #rows == 0 then 
      rows = List:new { tbl_cell(par(textrun("")), #cell_widths - 1) } 
    else 
      rows = rows:clone()
    end

    rows[1] = tbl_cell(par(textrun(label)), 1) .. rows[1]
    for i = 2, #rows do 
      rows[i] = tbl_cell(par(textrun("")), 1) .. rows[i]
    end

    return rows
  end

  local function render_text_row(text, cell_widths)
    local inlines = parse_markdown_inlines(text)
    return tbl_cell(par(render_inlines(inlines)), #cell_widths)
  end

  local function render_example_block_rows(block, has_judgement, cell_widths)
    local rows = List:new {}
    local example_cell_widths
    local next_subexample = 1

    if has_judgement then 
      example_cell_widths = cell_widths:slice(2)
    else 
      example_cell_widths = cell_widths
    end

    -- render every item
    for _, item in ipairs(block.items) do 
      local t = item.type
      if t == "text" then 
        rows:insert(render_text_row(item.lines, cell_widths))
      elseif t == "plain_example" then 
        -- example itself
        local example_row = ""
        if has_judgement then example_row = tbl_cell(par(textrun(item.judgement)), 1) end
        example_row = example_row .. tbl_cell(par(textrun(("\n"):join(item.text), "<w:i/>")), #example_cell_widths)

        if item.header then rows:insert(render_text_row(item.header, cell_widths)) end
        rows:insert(example_row)
        if item.footer then rows:insert(render_text_row(item.footer, cell_widths)) end
      elseif t == "interlinearized_example" then 
        -- example itself
        local example_rows = render_gloss_rows(item.glosses, example_cell_widths)
        if has_judgement then example_rows = add_label_column(example_rows, item.judgement, cell_widths) end

        if item.header then rows:insert(render_text_row(item.header, cell_widths)) end
        rows:extend(example_rows)
        if item.footer then rows:insert(render_text_row(item.footer, cell_widths)) end
      elseif t == "block" then
        local block_rows = render_example_block_rows(item, has_judgement, cell_widths:slice(2))
        local label =   string.char(string.byte("a") + next_subexample - 1) .. "."
        block_rows = add_label_column(block_rows, label, cell_widths)
        next_subexample = next_subexample + 1
        rows:extend(block_rows)
      end
    end

    return rows
  end


  


  local function get_example_properties(block) 
    local inner_label = false
    local longest_judgement = ""
    local glosses = false

    for _, item in ipairs(block.items) do 
      local judgement1, glosses1

      if item.type == "block" then 
        _, judgement1, glosses1 = get_example_properties(item)
        inner_label = true
      else 
        judgement1 = item.judgement or ""
        glosses1 = item.glosses ~= nil
      end

      if #longest_judgement < #judgement1 then longest_judgement = judgement1 end
      glosses = glosses or glosses1
    end

    return inner_label, longest_judgement, glosses
  end

  local function compute_cell_widths(label, has_inner_label, longest_judgement, has_glosses)
    local cell_widths = List:new {}

    -- outer label
    cell_widths:insert(estimate_dxa_width_for_text(label))

    -- inner label
    if has_inner_label then
      cell_widths:insert(estimate_dxa_width_for_text("a."))    
    end

    -- judgement
    if #longest_judgement > 0 then
      cell_widths:insert(estimate_dxa_width_for_text(longest_judgement) - estimate_dxa_width_for_text(""))    
    end    

    -- remaining cells
    local width_remaining = full_table_width
    for _, w in ipairs(cell_widths) do width_remaining = width_remaining - w end

    if has_glosses then 
      for _ = 1, math.floor(width_remaining/gloss_cell_width) do 
        cell_widths:insert(gloss_cell_width) 
      end
    else 
      cell_widths:insert(width_remaining)    
    end  

    return cell_widths
  end


  -- let's to rendering first...
  function docx_render_example(example, label)
    -- this is the columns structure:
    --
    -- | outer label | inner label | judgement | glosses ... |
    --

    -- scan the example to detect how many columns we need
    local has_inner_label, longest_judgement, has_glosses = get_example_properties(example)
    local has_judgement = #longest_judgement > 0

    -- cell widths
    local cell_widths = compute_cell_widths(label, has_inner_label, longest_judgement, has_glosses)


    -- render the example block (removing the first column)
    local rows = render_example_block_rows(example, has_judgement, cell_widths:slice(2))

    -- add the label
    rows = add_label_column(rows, label, cell_widths)

    -- generate the table header
    local colspec = (""):join(cell_widths:map(tbl_col_spec))
    colspec = "<w:tblGrid>" .. colspec .. "</w:tblGrid>"

    -- assemble the table
    local tbl_body = ""
    local row_props = "<w:trPr><w:tblHeader w:val=\"false\"/></w:trPr>"
    for _, row in ipairs(rows) do tbl_body = tbl_body .. "<w:tr>" .. row_props .. row .. "</w:tr>" end

    local tbl = "<w:tbl>" .. table_props .. colspec .. tbl_body .. "</w:tbl>"

    -- surround it with empty paragraphs, as Word concatenates tables
    tbl = tbl .. par(textrun(""))


    return pandoc.RawBlock("openxml", tbl)
  end  
end
-- DOCX support


-- LATEX support
do
  local pandoc_type = pandoc.utils.type
  local nopagebreak = "\\nopagebreak[2]"

  -- example contents are output as a specially styled single-item 
  -- with grammaticality judgement as list labels
  --
  -- this template has two arguments: the grammaticality judgement and the 
  -- example body proper

  -- example contents are output as a specially styled single-item 
  -- with grammaticality judgement as list labels
  local function render_example_body(body, judgement)
    -- judgement is rendered as a list mark
    if judgement == nil then judgement = "" end 
    if judgement ~= "" then 
      judgement = "\\mbox{}\\llap{\\makejudgementmark{" .. judgement .. "}}\\ignorespaces" 
    end

    -- emit the example
    return judgement .. body
  end


  local function render_block_body(body, label, is_outer, is_inner, longest_judgement)
    local judgement_box = ""
    if longest_judgement ~= "" then 
      judgement_box = "\\makejudgementmark{" .. longest_judgement .. "}" 
    end

    -- emit the list containing the block
    local out = ""
    out = out .. "\\begin{list}{}{" .. "\n"
    -- outermost list block has to set up the formatting and spacing
    if is_outer then 
      -- formatting commands
      out = out .. "\\providecommand{\\makejudgementmark}[1]{\\rmfamily\\footnotesize\\raisebox{0.4ex}{#1}}\n"
      out = out .. "\\providecommand{\\transcriptionstyle}{\\rmfamily\\itshape}\n"
      out = out .. "\\providecommand{\\glossstyle}{\\rmfamily}\n"
      out = out .. "\\providecommand{\\featureglossstyle}{\\rmfamily\\scshape}\n"
      -- spacing for the judgement marker
      out = out .. "\\ifdefined\\judgementwidth\\relax\\else\\newlength{\\judgementwidth}\\fi\n"
      out = out .. "\\settowidth{\\judgementwidth}{" .. judgement_box .. "}\n"     
      out = out .. "\\ifdim\\judgementwidth<0.25em\\setlength{\\judgementwidth}{0pt}\\fi\n" 
    end
    -- label width is set to the width of the actual label to get proper alignment
    -- is there a better way of doing it? I find the list environment controls to 
    -- be rather unintuitive... 
    out = out .. "\\settowidth{\\labelwidth}{" .. label .. "}\n"
    -- spacing between the label and the content depends on whether 
    -- we have to accomodate the judgement marker (only for inner blocks)
    if is_inner then 
      out = out .. "\\setlength{\\labelsep}{\\dimexpr\\judgementwidth+0.25em\\relax}\n"
    else 
      out = out .. "\\setlength{\\labelsep}{0.25em}\n"
    end
    -- left margin is set so that the label is left-aligned 
    -- from LaTeX unnoficial manual: 
    --
    --   the left edge of the label box is \leftmargin+\itemindent-\labelsep-\labelwidth
    --  
    out = out .. "\\setlength{\\leftmargin}{\\dimexpr\\labelsep+\\labelwidth-\\itemindent\\relax}\n"
    -- vertical spacing
    out = out .. "\\setlength{\\parsep}{0pt}\n"
    out = out .. "\\setlength{\\topsep}{0pt}\n"
    -- end of spacing block
    out = out .. "}\n"
    
    -- need this to fix glosses spacing
    out = out .. "\\lineskip=0.4\\baselineskip\n"

    -- add the body
    out = out .. "\\item[" .. label .. "]\n"
    out = out .. body .. "\n"
    out = out .. "\\end{list}\n"

    return out
  end  

  local function reindent_lines(lines, indent)
    assert(pandoc_type(lines) == "List")
    if #lines == 0 then return lines end

    -- find and remove the block indentation
    local indent0 = math.huge
    for _, line in ipairs(lines) do 
      local _, ii = lines[1]:find("^%s*()")
      indent0 = math.min(ii, indent0)
    end
    if indent0 > 1 then 
      lines = lines:map(function(line) return line:sub(indent0) end)
    end

    local indent_str = string.rep(" ", indent)
    return lines:map(function(line) return indent_str .. line end)
  end

  local function get_example_properties(block) 
    local inner_label = false
    local longest_judgement = ""
    local glosses = false

    for _, item in ipairs(block.items) do 
      local judgement1, glosses1

      if item.type == "block" then 
        _, judgement1, glosses1 = get_example_properties(item)
        inner_label = true
      else 
        judgement1 = item.judgement or ""
        glosses1 = item.glosses ~= nil
      end

      if #longest_judgement < #judgement1 then longest_judgement = judgement1 end
      glosses = glosses or glosses1
    end

    return inner_label, longest_judgement, glosses
  end

  local function render_gloss_cell(glosses)
    if #glosses == 0 then return "\\hbox{}" end

    local out = "\\hbox{\\transcriptionstyle\\ignorespaces " .. glosses[1] .. "}"
    for i = 2, #glosses do 
      local token_str = ""
      for token, type in iterate_glosses(glosses[i]) do 
        if type == "gloss" then 
          token = "{\\featureglossstyle " .. token:lower() .. "}"
        end
        token_str = token_str .. token
      end
      out = out .. "\\hbox{" .. token_str .. "}"
    end

    return "\\mbox{\\vtop{" .. out .. "}}"
  end

  local function render_glosses(glosses_list)
    local out = "\\noindent"

    for _, glosses in ipairs(glosses_list) do 
      out = out .. "\n" .. render_gloss_cell(glosses)
    end

    return out
  end

  local function render_text(text)
    if text == nil then return "" end

    local inlines = parse_markdown_inlines(text)
    local doc = pandoc.Pandoc({ pandoc.Para(inlines) })
    return pandoc.write(doc, "latex")
  end  

  local function render_example_block(block, label)
    local next_subexample = 1

    -- if this is an outer block we need to find the longest judgement label
    local is_outer = block.level == 0
    local longest_judgement = ""
    if is_outer then 
      _, longest_judgement, _ = get_example_properties(block)
    end

    -- this is an inner block if it contains no subexamples
    -- we will set that as we scan the block contents
    local is_inner = true

    -- the body is assembled here
    local body = List:new { }

    -- render every item
    for _, item in ipairs(block.items) do 
      local t = item.type
      if t == "text" then 
        local vskip = (#body > 0) and "\\vspace{0.5ex}\n" or ""

        body:insert(vskip .. render_text(item.lines))
      elseif t == "plain_example" then 
        -- the example body
        local example_body = "{\\transcriptionstyle\\ignorespaces " .. ("\n"):join(item.text) .. "}"

        -- assemble the example from parts
        if item.header then body:insert(render_text(item.header) .. "\\vspace{0.5ex}\n" .. nopagebreak) end 
        body:insert(render_example_body(example_body, item.judgement))        
        if item.footer then body:insert(nopagebreak .. render_text(item.footer)) end 
      elseif t == "interlinearized_example" then 
        -- the example body
        local example_body = render_glosses(item.glosses)

        -- assemble the example from parts
        if item.header then body:insert(render_text(item.header) .. "\\vspace{0.5ex}\n" .. nopagebreak) end 
        body:insert(render_example_body(example_body, item.judgement))        
        if item.footer then body:insert(nopagebreak .. render_text(item.footer)) end 
      elseif t == "block" then
        is_inner = false
        local subexample_label = string.char(string.byte("a") + next_subexample - 1) .. "."
        next_subexample = next_subexample + 1

        body:insert("\\vspace{0.5ex}\n" .. render_example_block(item, subexample_label))
      end
    end

    -- render the block
    return render_block_body(("\n\n"):join(body), label, is_outer, is_inner, longest_judgement)
  end


  function latex_render_example(example, label)    
    -- render the example
    local out = render_example_block(example, label)

    -- add pagebreak hints
    out = "\\pagebreak[1]\n" .. out

    return pandoc.RawBlock("latex", out)
  end  
end

-- Reference processing
--
-- We detect references to glossed examples as pandoc citations in form of @gloss:label (
-- or @gloss:label.a for subreferences). A citation filter will parse these references, 
-- compact them (transforming reference lists such as 1, 4a, 3, 2, 4b into a nicely displayed
-- 1-4a,b) and render them as markdown. 
--
-- The exported functions are:
--
--   - process_gloss_references which is used as a Cite filter
--   - next_gloss_reference which will return a label for a new reference
do
  -- glossed example reference tracker
  local next_example_ref = 1
  local example_refs = {}

  -- record gloss reference and return the rendered label 
  function next_gloss_reference(ref_label) 
    -- example ref
    local ref = next_example_ref
    example_refs["gloss:#:" .. ref] = {ref = ref}
    next_example_ref = next_example_ref + 1

    if ref_label ~= nil then 
      example_refs["gloss:" .. ref_label] = {ref = ref}
    end

    return "(" .. ref .. ")"
  end

  -- parse a markdown gloss reference in shape of gloss:label
  local function try_parse_gloss_ref(ref)
    -- extract the gloss reference with the optional subexample label
    local sub = ref:match("%.([a-z])$")
    if sub ~= nil then 
      ref = ref:sub(1, #ref - 2)
      sub = sub:byte() - string.byte("a") + 1
    end

    -- check if the gloss id is recorded
    local ref_entry = example_refs[ref]

    if ref_entry == nil then return nil end

    -- TODO: check that subexample exists and mark as unknown otherwise
    return ref_entry.ref, sub
  end

  -- return a suitable text label for a reference
  local function format_reflabel(ref, type)
    if type == 0 then 
      return tostring(ref)
    elseif type == 1 then 
      return string.char(string.byte("a") + ref - 1)
    else 
      error("(fatal internal error) invalid gloss reference level " .. type)
    end
  end 

  -- return a text representation for the next component in the reference 
  -- this can be -3 or ,a etc. depending on the previous state
  local function format_next_ref(ref, type, prev_type, range_len) 
    -- transform subexample ref into an alphabetic label
    ref = format_reflabel(ref, type)

    -- find the appropriate delimiter
    if range_len > 2 then 
      return "-" .. ref
    elseif type > prev_type then 
      -- no spacing before the first subexample label
      return ref
    elseif type == 0 then 
      return ", " .. ref
    else 
      return "," .. ref
    end
  end

  -- this is responsible for formatting a list of references (given as pairs of reference and 
  -- subexample ids) into a compacted text representation such as (1-4a,b)
  function compact_references(refs) 
    if #refs == 0 then return nil end

    -- sort the refs and remove duplicates
    refs:sort(function(a, b) 
      if a[1] == b[1] then 
        return (a[2] or 0) < (b[2] or 0) 
      else
        return a[1] < b[1]
      end
    end)

    -- walk the refs, removing duplicates and pushing the entries onto the stack
    -- the stack is a pair of (level, ref) where level of 1 indicates a subexample
    local refstack = List:new()
    do 
      local i = 1
      local prev_ref, prev_sub = nil, nil
      while i <= #refs do 
        local ref, sub = table.unpack(refs[i])
        -- is this ref different from prev?
        -- note: empty subreference means that all other subreferences are ignored
        if ref ~= prev_ref or ((prev_sub ~= nil) and (prev_sub ~= sub)) then 
          -- push the ref onto the stack 
          if ref ~= prev_ref then refstack:insert({0, ref}) end
          if sub ~= nil then refstack:insert({1, sub}) end 
          
          -- update the previous state 
          prev_ref, prev_sub = ref, sub
        end

        i = i + 1
      end
    end 

    -- initial state
    local prev_type, prev = table.unpack(refstack[1])
    local range_len = 1

    local out = format_reflabel(prev, prev_type)

    for i = 2, #refstack do 
      local type, ref = table.unpack(refstack[i])

      -- we need flushing if either the type has changed or the range has been broken
      if type ~= prev_type or ref ~= prev + 1 then 
        -- flush the previous range, if any
        if range_len > 1 then 
          out = out .. format_next_ref(prev, prev_type, prev_type, range_len)
        end  
        -- write out the current ref
        out = out .. format_next_ref(ref, type, prev_type, 1)

        -- reset the state
        prev_type = type
        range_len = 1
      else
        -- continue compacting the range
        range_len = range_len + 1
      end

      prev = ref
    end
    -- flush the last range
    if range_len > 1 then 
      out = out .. format_next_ref(prev, prev_type, prev_type, range_len)
    end

    return out
  end

  -- support for @gloss:last and @gloss:prev
  local relative_ref_pat = (lpeg.P "gloss:") * 
    lpeg.C((lpeg.P "prev" + lpeg.P "last" + lpeg.P "next")^1) *
    lpeg.C((lpeg.S "+-" * (lpeg.R "09")^1)^-1) * 
    lpeg.C((lpeg.P "." * (lpeg.S "az")^1)^-1)

  function process_gloss_relative_references(elt)
    elt.citations = elt.citations:filter(function(cit)
      local origin, offset, suffix = lpeg.match(relative_ref_pat, cit.id)

      if origin ~= nil then 
        local ref = (origin == "next") and next_example_ref or (next_example_ref - 1)
        if offset ~= "" then ref = ref + tonumber(offset) end 
        cit.id = "gloss:#:" .. ref .. suffix
      end

      return cit
    end)

    return elt
  end

  function process_gloss_references(elt)
    -- walk the citation, references to glossed examples
    local refs = List:new()
    local has_gloss_references = false

    local remaining_citations = elt.citations:filter(function(cit)
      local ref, sub = try_parse_gloss_ref(cit.id)

      -- keep this citation if it's not a known gloss reference
      if ref == nil then return true end

      refs:insert({ ref, sub })

      -- remove this citation
      has_gloss_references = true
      return false
    end) 

    -- exit if there were no gloss references
    if not has_gloss_references then 
      return elt
    end

    -- format the references (compressing them if needed) and convert the output to inlines
    local out = pandoc.Inlines(compact_references(refs))

    -- if there are still unresolved references, we need to add the formatted reference 
    -- as a prefix
    if #remaining_citations > 0 then 
      out:insert(pandoc.Str(","))
      out:insert(pandoc.Space())
      if #remaining_citations[1].prefix > 0 then 
        out:extend(remaining_citations[1].prefix)
      end
      remaining_citations[1].prefix = pandoc.Inlines(out)
      elt.citations = remaining_citations
      return elt
    else
      out:insert(1, pandoc.Str("("))
      out:insert(pandoc.Str(")"))
      return pandoc.Inlines(out)
    end
  end
end


function process_gloss_block(block)
  if not block.classes:includes("gloss") then return block end 

  local example = parse_example(block.text)
  local out = nil

  -- format the example
  local label = next_gloss_reference(block.identifier)
  if FORMAT == "docx" then 
    out = docx_render_example(example, label)
  elseif FORMAT == "latex" then  
    out = latex_render_example(example, label)
  else
    out = block
  end

  return out
end


return {
  { Meta = setup_metadata_copy },
  { traverse = "topdown", CodeBlock = process_gloss_block, Cite = process_gloss_relative_references },
  { Meta = add_internal_citations, Cite = process_gloss_references}  
}




