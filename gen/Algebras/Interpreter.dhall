let Deps = ../Deps/package.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let Config =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
      }

let module =
      \(Input : Type) ->
      \(Output : Type) ->
        let Result = Deps.Lude.Compiled.Type Output

        let Run = Config -> Input -> Result

        in  \(run : Run) -> { Input, Output, Result, Run, run }

in  { Config, module }
