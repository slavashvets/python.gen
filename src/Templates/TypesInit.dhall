let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

let Export = { moduleName : Text, typeName : Text }

let Params = { exports : List Export }

let run =
      \(params : Params) ->
        let exportLines =
              Prelude.Text.concatMapSep
                "\n"
                Export
                ( \(export : Export) ->
                    "from .${export.moduleName} import ${export.typeName} as ${export.typeName}"
                )
                params.exports

        let exportSection =
              if    Prelude.List.null Export params.exports
              then  ""
              else  "# isort: off\n${exportLines}\n# isort: on"

        in  ''
            ${exportSection}
            ''

in  Sdk.Sigs.template Params run /\ { Export }
