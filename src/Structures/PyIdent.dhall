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

-- Add the caller's suffix when `name` collides with one of `reserved`. Callers
-- keep the raw name for the SQL placeholder / dict key / row[...] lookup; only
-- the Python identifier is sanitized.
--
-- Equality without Text/equal: java.gen's escapeJavaKeyword delimiter trick does
-- not apply here because pgn's embedded Text/replace misses needles spanning a
-- text concatenation boundary (verified against the pinned pgn), so a "|"-wrapped
-- name never matches its wrapped keyword. Bare replaces do work:
-- `Text/replace name markTrue candidate` yields exactly `markTrue` only when
-- `name` equals `candidate`; any mismatch residue keeps a letter of the
-- alphabetic reserved word or grows past the digits-only marker, so it can never
-- match inside `markTrue`, the second replace maps match to `name` and mismatch
-- to `markTrue`, and the final replace rewrites `acc` on a match only.
-- Limitations: a name containing the literal marker string is corrupted by the
-- mismatch branch (the marker becomes the needle replaced in `acc`), and `acc`
-- must be read exactly once per fold step or the expression re-embeds itself at
-- every reserved word and blows up exponentially.
let markTrue = "0000000000000000000000000001"

let suffixAgainst =
      \(suffix : Text) ->
      \(reserved : List Text) ->
      \(name : Text) ->
        List/fold
          Text
          reserved
          Text
          ( \(candidate : Text) ->
            \(acc : Text) ->
              let signal = Text/replace name markTrue candidate

              let finalNeedle = Text/replace signal name markTrue

              in  Text/replace finalNeedle (name ++ suffix) acc
          )
          name

let sanitizeAgainst = suffixAgainst "_"

let pySafeName
    : Text -> Text
    = sanitizeAgainst pythonKeywords

let moduleReservedNames =
      [ "_cast"
      , "_require_array"
      , "_fetch_optional"
      , "_fetch_single"
      , "_fetch_many"
      , "_execute_rows_affected"
      , "_execute_void"
      , "_decode_row"
      , "_types"
      , "date"
      , "datetime"
      , "time"
      , "timedelta"
      ]

let parameterReservedNames =
      [ "conn"
      , "sql"
      , "params"
      , "decode"
      , "cur"
      , "row"
      , "_decode_row"
      , "_fetch_optional"
      , "_fetch_single"
      , "_fetch_many"
      , "_execute_rows_affected"
      , "_execute_void"
      ]

let parameterSafeName
    : Text -> Text
    = sanitizeAgainst (pythonKeywords # parameterReservedNames)

let querySafeName =
      \(name : Text) -> suffixAgainst "_query" moduleReservedNames (pySafeName name)

in  { pythonKeywords
    , sanitizeAgainst
    , pySafeName
    , moduleReservedNames
    , parameterReservedNames
    , parameterSafeName
    , querySafeName
    }
