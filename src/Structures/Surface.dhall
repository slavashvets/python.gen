-- A code-generation surface: the async or sync flavour of a statement module.
-- Exactly one surface is emitted per generate (Interpreters/Project.dhall
-- picks async or sync from config.sync and renders everything at the same
-- unified paths), so the two Surface values differ only in the tokens that
-- vary between `async def`/`def`, `AsyncConnection`/`Connection`, and
-- `await `/``. Both reach the shared `_rows`/`_core`/`types` modules at the
-- same relative import depth, since neither surface is nested under a
-- surface-named subdirectory.
let Surface =
      { defKeyword : Text
      , connType : Text
      , awaitKw : Text
      , rowsImport : Text
      , corePrefix : Text
      , typesPrefix : Text
      }

let async
    : Surface
    = { defKeyword = "async def"
      , connType = "AsyncConnection"
      , awaitKw = "await "
      , rowsImport = ".._rows"
      , corePrefix = ".._core"
      , typesPrefix = "..types"
      }

let sync
    : Surface
    = { defKeyword = "def"
      , connType = "Connection"
      , awaitKw = ""
      , rowsImport = ".._rows"
      , corePrefix = ".._core"
      , typesPrefix = "..types"
      }

in  { Type = Surface, async, sync }
