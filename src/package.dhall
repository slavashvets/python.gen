let Sdk = ./Deps/Sdk.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let ProjectInterpreter = ./Interpreters/Project.dhall

-- User-facing config for this generator. `sync` picks which single surface
-- the generator emits: `False` (default) emits the async surface
-- (psycopg.AsyncConnection); `True` emits the sync surface
-- (psycopg.Connection) instead, at the exact same paths — flipping this
-- flag never changes the output tree's shape or any import path, only file
-- contents. `onUnsupported` picks Fail (default, abort loudly) or Skip (drop
-- the unsupported statement/type and its dependents, with a warning) when a
-- query or custom type hits a PG shape the generator cannot render; see
-- Structures/OnUnsupported.dhall. All fields are Optional so a project may
-- omit the whole config block or any subset of its keys;
-- Interpreters/Project.dhall's `run` supplies the defaults.
let Config =
      { packageName : Optional Text
      , sync : Optional Bool
      , onUnsupported : Optional OnUnsupported.Mode
      } : Type

let Config/default
    : Config
    = { packageName = None Text
      , sync = None Bool
      , onUnsupported = None OnUnsupported.Mode
      }

in  Sdk.Sigs.generator Config Config/default ProjectInterpreter.run
