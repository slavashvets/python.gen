let Contract = ./Deps/Contract.dhall

let Prelude = ./Deps/Prelude.dhall

let Config = ./Config.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let ProjectInterpreter = ./Interpreters/Project.dhall

-- Entry point handed to gen-sdk's Sdk.Sigs.generator as `interpret`. Each
-- field of Config is independently Optional, so a project may omit the
-- whole config block (Sdk.Sigs.generator substitutes an all-None
-- defaultConfig, see package.dhall) or any subset of its keys; `defaults`
-- collects every fallback in one place (packageName from the project name in
-- kebab case, emitSync off, onUnsupported Fail). The async surface is always
-- emitted; emitSync adds the sync mirror.
in  \(config : Config) ->
    \(project : Contract.Project) ->
      let defaults =
            { packageName = project.name.inKebabCase
            , emitSync = False
            , onUnsupported = OnUnsupported.Mode.Fail
            }

      let packageName =
            Prelude.Optional.fold
              Text
              config.packageName
              Text
              (\(t : Text) -> t)
              defaults.packageName

      let emitSync =
            Prelude.Optional.fold
              Bool
              config.emitSync
              Bool
              (\(b : Bool) -> b)
              defaults.emitSync

      let onUnsupported =
            Prelude.Optional.fold
              OnUnsupported.Mode
              config.onUnsupported
              OnUnsupported.Mode
              (\(m : OnUnsupported.Mode) -> m)
              defaults.onUnsupported

      let importName = Prelude.Text.replace "-" "_" packageName

      let interpreterConfig = { packageName, importName, emitSync, onUnsupported }

      in  ProjectInterpreter.run interpreterConfig project
