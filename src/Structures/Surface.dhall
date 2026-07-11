-- A code-generation surface: the async or sync flavour of a statement module.
-- Backend (async) and ingest (sync) share one project, one generate, and the
-- same Row dataclasses + enums; only the I/O wrapper differs per surface. The
-- fields are the exact tokens that vary between `async def`/`def`,
-- `AsyncConnection`/`Connection`, `await `/``, and the relative-import depth of
-- the shared `_rows`/`types` modules (sync statement modules sit one package
-- deeper under `sync/statements/`, so they reach the shared modules with an
-- extra dot). The runtime import is `.._runtime` for both surfaces (async from
-- `statements/`, sync from `sync/statements/`), so it needs no field here.
-- corePrefix mirrors rowsImport's depth: statement modules import JsonValue from
-- `_core` directly, so sync reaches it with an extra dot (`..._core`) exactly
-- like it reaches `_rows` (`..._rows`).
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
      , rowsImport = "..._rows"
      , corePrefix = "..._core"
      , typesPrefix = "...types"
      }

in  { Type = Surface, async, sync }
