let Sdk = ./Deps/Sdk.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let Config = ./Config.dhall

let Config/default
    : Config
    = { packageName = None Text
      , emitSync = None Bool
      , onUnsupported = None OnUnsupported.Mode
      }

let interpret = ./Interpret.dhall

in  Sdk.Sigs.generator Config Config/default interpret
