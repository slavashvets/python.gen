let Deps = ../Deps/package.dhall

let Algebra = ../Algebras/Template.dhall

let Export = { moduleName : Text, typeName : Text }

let Params = { exports : List Export }

let run =
      \(params : Params) ->
        let exportLines =
              Deps.Prelude.Text.concatMapSep
                "\n"
                Export
                ( \(export : Export) ->
                    "from .${export.moduleName} import ${export.typeName} as ${export.typeName}"
                )
                params.exports

        in  ''
            ${exportLines}
            ''

in  Algebra.module Params run /\ { Export }
