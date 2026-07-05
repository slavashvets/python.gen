let Deps = ./Deps/package.dhall

let Model = Deps.Project

let Prelude = Deps.Prelude

let Config = ./Config.dhall

let ProjectInterpreter = ./Interpreters/Project.dhall

-- Entry point handed to gen-sdk's module. `config` and each of its fields are
-- Optional, so a project may omit the whole config block or any subset of its
-- keys; `defaults` collects every fallback in one place (packageName from the
-- project name in kebab case, emitSync off), so a future knob's default is added
-- here alongside the others. The async surface is always emitted; emitSync adds
-- the sync mirror.
in  \(config : Optional Config) ->
    \(project : Model.Project) ->
      let defaults = { packageName = project.name.inKebabCase, emitSync = False }

      let packageName =
            Prelude.Optional.fold
              Config
              config
              Text
              (\(c : Config) ->
                Prelude.Optional.fold Text c.packageName Text (\(t : Text) -> t) defaults.packageName
              )
              defaults.packageName

      let emitSync =
            Prelude.Optional.fold
              Config
              config
              Bool
              (\(c : Config) ->
                Prelude.Optional.fold Bool c.emitSync Bool (\(b : Bool) -> b) defaults.emitSync
              )
              defaults.emitSync

      let importName = Prelude.Text.replace "-" "_" packageName

      let interpreterConfig =
            { packageName, importName, emitSync }

      in  ProjectInterpreter.run interpreterConfig project
