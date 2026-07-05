-- User-facing config for this generator. `emitSync` adds a parallel sync surface
-- (psycopg.Connection) alongside the default async one, so one project can serve
-- both an async backend and a sync (Dagster) consumer from shared Row types. Both
-- fields are Optional so a project may omit the whole config block or any subset
-- of its keys; compile.dhall supplies the defaults.
{ packageName : Optional Text, emitSync : Optional Bool } : Type
