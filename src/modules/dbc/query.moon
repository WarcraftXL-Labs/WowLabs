--- A small SQL-like language for finding rows.
--
-- A DBC table is two hundred columns of numbers with names nobody chose for
-- readability, so "the row I want" is almost never a row number. It is
-- `Name LIKE 'Fire%'`, or `SpellLevel > 60 AND SpellIconID != 0`.
--
--     Name LIKE 'Fire%'
--     SpellLevel >= 60 AND Category = 0
--     Name CONTAINS 'bolt' OR Description CONTAINS 'bolt'
--     NOT (SpellLevel = 0)
--
-- Operators: `=` `!=` `<` `<=` `>` `>=`, and the text ones `LIKE` (with SQL's
-- `%` and `_` wildcards), `CONTAINS`, `STARTS` and `ENDS`. Joined with `AND`,
-- `OR` and `NOT`, grouped with parentheses.
--
-- **Text comparisons ignore case**, all of them. A tool whose search misses
-- "Fireball" because the user typed "fireball" is a tool people stop using,
-- and nothing in a DBC distinguishes two strings by case alone on purpose.
--
-- **A number compares as a number when both sides are numbers**, so
-- `SpellLevel > 9` does not put 10 before 9 the way a string compare would.
---@module modules.dbc.query

M = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- Tokens
-- ═══════════════════════════════════════════════════════════════════════════

KEYWORDS = {
  AND: "and", OR: "or", NOT: "not"
  LIKE: "like", CONTAINS: "contains", STARTS: "starts", ENDS: "ends"
}

-- Longest first: scanning for "<" before "<=" would read "<=" as "<" and then
-- fail on a stray "=".
OPERATORS = { "<=", ">=", "!=", "<>", "==", "=", "<", ">" }

--- Splits a query into tokens.
---@param text string
---@return table[]|nil tokens, string|nil err
---@private
scan = (text) ->
  tokens = {}
  at = 1
  size = #text

  while at <= size
    char = text\sub at, at

    if char\match "%s"
      at += 1
      continue

    -- A quoted string, either quote, with the other usable inside it. No
    -- escapes: a DBC string holding a quote is reachable with the other one,
    -- and backslash rules are a thing to explain that nobody would read.
    if char == "'" or char == '"'
      finish = text\find char, at + 1, true
      return nil, "unterminated string" unless finish
      -- Parenthesised: an unparenthesised call swallows what follows it, so
      -- `text\sub at + 1, finish - 1, text: true` passes `text: true` to sub
      -- as a third argument and never marks the token as text at all.
      table.insert tokens, {
        kind: "value"
        value: (text\sub at + 1, finish - 1)
        text: true
      }
      at = finish + 1
      continue

    if char == "(" or char == ")"
      table.insert tokens, { kind: char }
      at += 1
      continue

    found = nil
    for operator in *OPERATORS
      if text\sub(at, at + #operator - 1) == operator
        found = operator
        break

    if found
      table.insert tokens, { kind: "op", op: found }
      at += #found
      continue

    -- A bare word: a column name, a keyword, a number, or an unquoted value.
    -- Column names carry underscores and digits; a value may carry a dot or a
    -- sign. Letting both through the same rule is what makes `Name = Fire`
    -- work without quotes.
    word = text\match "^[%w_%.%-%+%[%]]+", at
    return nil, "cannot read #{text\sub at, at}" unless word and #word > 0

    upper = word\upper!
    if KEYWORDS[upper]
      table.insert tokens, { kind: KEYWORDS[upper] }
    else
      table.insert tokens, { kind: "word", value: word }

    at += #word

  tokens, nil

-- ═══════════════════════════════════════════════════════════════════════════
-- Comparing
-- ═══════════════════════════════════════════════════════════════════════════

--- Turns SQL's wildcards into a Lua pattern.
--
-- Everything magic in a Lua pattern is escaped first, then `%` becomes `.*`
-- and `_` becomes `.`. Done the other way round the escaping would eat the
-- wildcards it had just written.
---@param text string
---@return string pattern
---@private
like_pattern = (text) ->
  escaped = text\gsub "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"
  escaped = escaped\gsub "%%%%", "\1"   -- the SQL % , now escaped as %%
  escaped = escaped\gsub "_", "."
  escaped = escaped\gsub "\1", ".*"
  "^" .. escaped .. "$"

--- Compares one cell against one literal.
---@param op string
---@param left any The cell.
---@param right string The literal, as written.
---@param text_literal boolean Whether it was quoted.
---@return boolean
---@private
compare = (op, left, right, text_literal) ->
  -- Numeric when both sides are numbers and the literal was not quoted.
  -- Quoting is how someone says "compare this as text" on a column that
  -- happens to hold digits.
  left_number = tonumber left
  right_number = not text_literal and tonumber(right) or nil

  if left_number and right_number
    switch op
      when "=", "==" then return left_number == right_number
      when "!=", "<>" then return left_number != right_number
      when "<" then return left_number < right_number
      when "<=" then return left_number <= right_number
      when ">" then return left_number > right_number
      when ">=" then return left_number >= right_number

  a = (tostring left or "")\lower!
  b = (tostring right or "")\lower!

  switch op
    when "=", "==" then a == b
    when "!=", "<>" then a != b
    when "<" then a < b
    when "<=" then a <= b
    when ">" then a > b
    when ">=" then a >= b
    when "like" then (a\match like_pattern b) != nil
    when "contains" then (a\find b, 1, true) != nil
    when "starts" then a\sub(1, #b) == b
    when "ends" then #b <= #a and a\sub(#a - #b + 1) == b
    else false

-- ═══════════════════════════════════════════════════════════════════════════
-- Parsing
-- ═══════════════════════════════════════════════════════════════════════════

-- Recursive descent, lowest precedence outermost: OR binds loosest, then AND,
-- then NOT, then a comparison. Each level returns a function of `get`, so the
-- parsed query is a closure rather than a tree something else has to walk.

parse_or = nil   -- forward declared: parse_primary recurses back into it

--- `column op value`, or a bare word meaning "contains, anywhere".
---@private
parse_comparison = (state) ->
  token = state.tokens[state.at]
  return nil, "expected a column name" unless token

  if token.kind == "value" or token.kind == "word"
    ahead = state.tokens[state.at + 1]

    -- A lone term with no operator searches every column. Typing "fireball"
    -- and getting the rows holding it is what a person expects from a box,
    -- and demanding a column name first would make the simple case the
    -- awkward one.
    unless ahead and (ahead.kind == "op" or KEYWORDS[(ahead.kind or "")\upper!])
      state.at += 1
      needle = token.value
      return ((get) -> get(nil, needle)), nil

    state.at += 1
    operator = ahead.kind == "op" and ahead.op or ahead.kind
    state.at += 1

    literal = state.tokens[state.at]
    return nil, "expected a value after #{operator}" unless literal and
      (literal.kind == "value" or literal.kind == "word")
    state.at += 1

    column = token.value
    quoted = literal.text and true or false
    value = literal.value

    return ((get) ->
      cell = get column
      return false if cell == nil
      compare operator, cell, value, quoted), nil

  nil, "expected a column name, found #{token.kind}"

---@private
parse_primary = (state) ->
  token = state.tokens[state.at]
  return nil, "the query ends too early" unless token

  if token.kind == "("
    state.at += 1
    inner, err = parse_or state
    return nil, err unless inner
    closing = state.tokens[state.at]
    return nil, "expected a closing bracket" unless closing and closing.kind == ")"
    state.at += 1
    return inner, nil

  if token.kind == "not"
    state.at += 1
    inner, err = parse_primary state
    return nil, err unless inner
    return ((get) -> not inner get), nil

  parse_comparison state

---@private
parse_and = (state) ->
  left, err = parse_primary state
  return nil, err unless left

  while state.tokens[state.at] and state.tokens[state.at].kind == "and"
    state.at += 1
    right, failed = parse_primary state
    return nil, failed unless right

    -- Through locals: `left` is reassigned each turn of the loop, so a closure
    -- reading it would see only the last one.
    a, b = left, right
    left = (get) -> a(get) and b(get)

  left, nil

parse_or = (state) ->
  left, err = parse_and state
  return nil, err unless left

  while state.tokens[state.at] and state.tokens[state.at].kind == "or"
    state.at += 1
    right, failed = parse_and state
    return nil, failed unless right

    a, b = left, right
    left = (get) -> a(get) or b(get)

  left, nil

--- Compiles a query.
--
-- The returned function is given a reader: `get(column_name)` answers that
-- column's value for the row being tested, and `get(nil, needle)` answers
-- whether any column holds `needle`. Which is to say the query knows nothing
-- about records, and the editor knows nothing about parsing.
---@param text string
---@return fun(get: function): boolean|nil predicate, string|nil err
M.compile = (text) ->
  text = tostring(text or "")
  return nil, nil if text\match "^%s*$"

  tokens, err = scan text
  return nil, err unless tokens
  return nil, nil if #tokens == 0

  -- Words and nothing else: the whole line is what is being looked for.
  -- Somebody typing "Fire Bolt" means that phrase, and reading it as a column
  -- called Fire followed by a syntax error would be technically defensible
  -- and useless. One word already takes the same path lower down.
  plain = true
  for token in *tokens
    unless token.kind == "word" or token.kind == "value"
      plain = false
      break

  if plain and #tokens > 1
    phrase = text\match "^%s*(.-)%s*$"
    return ((get) -> get nil, phrase), nil

  state = { :tokens, at: 1 }
  predicate, failed = parse_or state
  return nil, failed unless predicate

  if state.at <= #tokens
    left = state.tokens[state.at]
    return nil, "unexpected #{left.value or left.kind}"

  predicate, nil

M
