let Sdk = ./Deps/Sdk.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let PythonNameMapping = ./Structures/PythonNameMapping.dhall

let ProjectInterpreter = ./Interpreters/Project.dhall

-- User-facing config for this generator. Async output is always emitted;
-- `emitSync = True` adds a sync facade, runtime, and adjacent query functions.
-- `onUnsupported` picks Fail (default, abort loudly) or Skip (drop
-- the unsupported statement/type and its dependents, with a warning) when a
-- query or custom type hits a PG shape the generator cannot render; see
-- Structures/OnUnsupported.dhall. All fields are Optional so a project may
-- omit the whole config block or any subset of its keys;
-- Interpreters/Project.dhall's `run` supplies the defaults. Typed name mappings
-- provide explicit whole-entity renames after collision checks.
let Config =
      { packageName : Optional Text
      , emitSync : Optional Bool
      , onUnsupported : Optional OnUnsupported.Mode
      , queryNameMappings : Optional (List PythonNameMapping.Query)
      , customTypeNameMappings : Optional (List PythonNameMapping.CustomType)
      } : Type

let Config/default
    : Config
    = { packageName = None Text
      , emitSync = None Bool
      , onUnsupported = None OnUnsupported.Mode
      , queryNameMappings = None (List PythonNameMapping.Query)
      , customTypeNameMappings = None (List PythonNameMapping.CustomType)
      }

in  Sdk.Sigs.generator Config Config/default ProjectInterpreter.run
