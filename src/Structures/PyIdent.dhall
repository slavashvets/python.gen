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

let moduleMetadataNames =
      [ "__init__"
      , "__path__"
      , "__package__"
      , "__spec__"
      , "__name__"
      , "__loader__"
      , "__file__"
      , "__cached__"
      , "__builtins__"
      , "__annotations__"
      , "__all__"
      ]

let moduleReservedNames =
      [ "_db_types"
      , "_args_row"
      , "_fetch_optional"
      , "_fetch_single"
      , "_fetch_many"
      , "_execute_rows_affected"
      , "_execute_void"
      , "_fetch_optional_sync"
      , "_fetch_single_sync"
      , "_fetch_many_sync"
      , "_execute_rows_affected_sync"
      , "_execute_void_sync"
      , "sync"
      , "register_types"
      , "date"
      , "datetime"
      , "time"
      , "timedelta"
      ] # moduleMetadataNames

let parameterReservedNames =
      [ "conn"
      , "sql"
      , "params"
      , "decode"
      , "cur"
      , "row"
      , "_args_row"
      , "_fetch_optional"
      , "_fetch_single"
      , "_fetch_many"
      , "_execute_rows_affected"
      , "_execute_void"
      , "_fetch_optional_sync"
      , "_fetch_single_sync"
      , "_fetch_many_sync"
      , "_execute_rows_affected_sync"
      , "_execute_void_sync"
      ]

let parameterSafeName
    : Text -> Text
    = sanitizeAgainst (pythonKeywords # parameterReservedNames)

let querySafeName =
      \(name : Text) -> suffixAgainst "_query" moduleReservedNames (pySafeName name)

let typeModuleSafeName =
      \(name : Text) -> sanitizeAgainst (pythonKeywords # moduleMetadataNames) name

let asciiLetters =
      [ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"
      , "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"
      , "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M"
      , "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
      ]

let digits = [ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" ]

let containsOnly =
      \(allowed : List Text) ->
      \(name : Text) ->
        let residue =
              List/fold
                Text
                allowed
                Text
                (\(character : Text) -> \(rest : Text) -> Text/replace character "" rest)
                name

        in  Text/equal residue ""

-- The string is already limited to identifier characters before this check, so
-- its Text/show value contains a quote only at each end. Replacing `"<char>` can
-- therefore match only the first character and gives us a safe head predicate
-- without a non-standard regex builtin.
let startsWithOneOf =
      \(allowed : List Text) ->
      \(name : Text) ->
        let shown = Text/show name

        in  Prelude.List.any
              Text
              ( \(character : Text) ->
                  Prelude.Bool.not
                    ( Text/equal
                        (Text/replace ("\"" ++ character) "" shown)
                        shown
                    )
              )
              allowed

let isSnakeIdentifier =
      \(name : Text) ->
        let letters = Prelude.List.take 26 Text asciiLetters

        in  Prelude.Bool.not (Text/equal name "")
            && containsOnly (letters # digits # [ "_" ]) name
            && startsWithOneOf letters name

let isPascalIdentifier =
      \(name : Text) ->
        let uppercaseLetters = Prelude.List.drop 26 Text asciiLetters

        in  Prelude.Bool.not (Text/equal name "")
            && containsOnly (asciiLetters # digits) name
            && startsWithOneOf uppercaseLetters name

in  { pythonKeywords
    , moduleMetadataNames
    , sanitizeAgainst
    , pySafeName
    , moduleReservedNames
    , parameterReservedNames
    , parameterSafeName
    , querySafeName
    , typeModuleSafeName
    , isSnakeIdentifier
    , isPascalIdentifier
    }
