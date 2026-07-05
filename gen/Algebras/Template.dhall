let module =
      \(Params : Type) ->
        let Run = Params -> Text in \(run : Run) -> { Params, Run, run }

in  { module }
