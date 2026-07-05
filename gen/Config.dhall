-- User-facing config for this generator. `emitSync` adds a parallel sync surface
-- (psycopg.Connection) alongside the default async one, so one project can serve
-- both an async backend and a sync (Dagster) consumer from shared Row types.
{ packageName : Text, emitSync : Bool } : Type
