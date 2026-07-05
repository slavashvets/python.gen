let Prelude = ../Deps/Prelude.dhall

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

-- Suffix an underscore when `name` collides with one of `reserved`. Callers keep
-- the raw name for the SQL placeholder / dict key / row[...] lookup; only the
-- Python identifier is sanitized.
-- NOTE: Text/equal is a builtin supplied by pgn's embedded Dhall evaluator, not
-- by Dhall standard 23.1.0 (the pinned Prelude has no Text equality). The whole
-- generator therefore type-checks/evaluates under pgn but not the standalone dhall
-- CLI; CI runs generation only through pgn (version asserted == 0.6.5). Project.dhall
-- relies on the same builtin.
let sanitizeAgainst =
      \(reserved : List Text) ->
      \(name : Text) ->
        if    Prelude.List.any Text (\(r : Text) -> Text/equal name r) reserved
        then  name ++ "_"
        else  name

let pySafeName
    : Text -> Text
    = sanitizeAgainst pythonKeywords

in  { pythonKeywords, sanitizeAgainst, pySafeName }
