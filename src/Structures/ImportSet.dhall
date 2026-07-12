let Prelude = ../Deps/Prelude.dhall

-- A custom-type import line: "from ..types.<moduleName> import <className>".
-- Emitted in encounter order (the order the referencing columns/params were
-- declared), not sorted. Dhall (upstream) has no Text comparison, so there is
-- no way to alphabetize or dedupe by moduleName/className without either the
-- pgn fork's Text/equal or a project-wide Natural id (previously `order`,
-- sourced from Project.dhall's buildLookup — see
-- docs/plans/2026-07-11-encounter-order-custom-imports.md for why that's
-- gone and why dedup isn't reintroduced some other way). Two references to
-- the same type currently produce two identical lines; harmless to Python
-- and to basedpyright, just not deduped.
let CustomImport = { className : Text, moduleName : Text }

let Self =
      { uuid : Bool
      , datetime : Bool
      , date : Bool
      , time : Bool
      , timedelta : Bool
      , decimal : Bool
      , jsonb : Bool
      , json : Bool
      , jsonValue : Bool
      , enumArray : Bool
      , customTypes : List CustomImport
      }

let base =
      { uuid = False
      , datetime = False
      , date = False
      , time = False
      , timedelta = False
      , decimal = False
      , jsonb = False
      , json = False
      , jsonValue = False
      , enumArray = False
      , customTypes = [] : List CustomImport
      }

let empty
    : Self
    = base

let uuid
    : Self
    = base // { uuid = True }

let datetime
    : Self
    = base // { datetime = True }

let date
    : Self
    = base // { date = True }

let time
    : Self
    = base // { time = True }

let timedelta
    : Self
    = base // { timedelta = True }

let decimal
    : Self
    = base // { decimal = True }

let jsonb
    : Self
    = base // { jsonb = True }

let json
    : Self
    = base // { json = True }

let jsonValue
    : Self
    = base // { jsonValue = True }

let enumArray
    : Self
    = base // { enumArray = True }

let custom
    : CustomImport -> Self
    = \(c : CustomImport) -> base // { customTypes = [ c ] }

let combine =
      \(left : Self) ->
      \(right : Self) ->
        { uuid = left.uuid || right.uuid
        , datetime = left.datetime || right.datetime
        , date = left.date || right.date
        , time = left.time || right.time
        , timedelta = left.timedelta || right.timedelta
        , decimal = left.decimal || right.decimal
        , jsonb = left.jsonb || right.jsonb
        , json = left.json || right.json
        , jsonValue = left.jsonValue || right.jsonValue
        , enumArray = left.enumArray || right.enumArray
        , customTypes = left.customTypes # right.customTypes
        }

let combineAll
    : List Self -> Self
    = \(sets : List Self) -> List/fold Self sets Self combine empty

in  { Type = Self
    , CustomImport
    , empty
    , uuid
    , datetime
    , date
    , time
    , timedelta
    , decimal
    , jsonb
    , json
    , jsonValue
    , enumArray
    , custom
    , combine
    , combineAll
    }
