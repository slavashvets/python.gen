-- User-facing config for this generator. `emitSync` adds a parallel sync surface
-- (psycopg.Connection) alongside the default async one, so one project can serve
-- both an async backend and a sync (Dagster) consumer from shared Row types.
-- `onUnsupported` picks Fail (default, abort loudly) or Skip (drop the
-- unsupported statement/type and its dependents, with a warning) when a query
-- or custom type hits a PG shape the generator cannot render; see
-- Structures/OnUnsupported.dhall. All fields are Optional so a project may omit
-- the whole config block or any subset of its keys; compile.dhall supplies the
-- defaults.
let OnUnsupported = ./Structures/OnUnsupported.dhall

in  { packageName : Optional Text
    , emitSync : Optional Bool
    , onUnsupported : Optional OnUnsupported.Mode
    } : Type
