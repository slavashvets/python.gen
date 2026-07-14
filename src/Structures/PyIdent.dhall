-- pgn passes identifier names through verbatim (the keyword-param fixture proves a
-- column or placeholder may be spelled as a Python reserved word), so any name that
-- becomes a Python identifier in the emitted code must be sanitized. Shared so the
-- params signature, the result-row dataclass fields, and composite fields all use
-- one rule.
let pythonKeywords =
      [ "False"
      , "None"
      , "True"
      , "and"
      , "as"
      , "assert"
      , "async"
      , "await"
      , "break"
      , "class"
      , "continue"
      , "def"
      , "del"
      , "elif"
      , "else"
      , "except"
      , "finally"
      , "for"
      , "from"
      , "global"
      , "if"
      , "import"
      , "in"
      , "is"
      , "lambda"
      , "nonlocal"
      , "not"
      , "or"
      , "pass"
      , "raise"
      , "return"
      , "try"
      , "while"
      , "with"
      , "yield"
      ]

let Lude = ../Deps/Lude.dhall

-- Suffix an underscore when `name` collides with one of `reserved`. Callers keep
-- the raw name for the SQL placeholder / dict key / row[...] lookup; only the
-- Python identifier is sanitized.
-- Dhall (and pgn's evaluator, as of pgn 0.11.0) has no Text/equal builtin, so
-- Lude.Text.replaceIfOneOf gets exact-match replacement via a sentinel-wrapped
-- Text/replace instead.
let sanitizeAgainst
    : List Text -> Text -> Text
    = \(reserved : List Text) ->
      \(name : Text) ->
        Lude.Text.replaceIfOneOf reserved (name ++ "_") name

let pySafeName
    : Text -> Text
    = sanitizeAgainst pythonKeywords

in  { pythonKeywords, sanitizeAgainst, pySafeName }
