let Deps = ./Deps/package.dhall

let Model = Deps.Project

let Prelude = Deps.Prelude

let Config = ./Config.dhall

let ProjectInterpreter = ./Interpreters/Project.dhall

-- Entry point handed to gen-sdk's module. Derives the internal interpreter
-- config from the optional user config (packageName falling back to the project
-- name in kebab case; emitSync falling back to False), then delegates to the
-- Project traversal. The async surface is always emitted; emitSync adds the sync
-- mirror.
in  \(config : Optional Config) ->
    \(project : Model.Project) ->
      let packageName =
            Prelude.Optional.fold
              Config
              config
              Text
              (\(c : Config) -> c.packageName)
              project.name.inKebabCase

      let emitSync =
            Prelude.Optional.fold
              Config
              config
              Bool
              (\(c : Config) -> c.emitSync)
              False

      let importName = Prelude.Text.replace "-" "_" packageName

      let interpreterConfig =
            { packageName, importName, emitSync }

      in  ProjectInterpreter.run interpreterConfig project
