let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

let Field = { fieldName : Text, fieldType : Text }

-- extraImports are the extra import lines a field type needs (e.g.
-- "from uuid import UUID"). They sit between the dataclass import and the class,
-- separated by one blank line; when empty only the dataclass import is emitted.
let Params = { typeName : Text, extraImports : List Text, fields : List Field }

let run =
      \(params : Params) ->
        let fieldLines =
              Prelude.Text.concatMapSep
                "\n"
                Field
                ( \(field : Field) ->
                    "    ${field.fieldName}: ${field.fieldType}"
                )
                params.fields

        let imports =
              if    Prelude.List.null Text params.extraImports
              then  "from dataclasses import dataclass"
              else  ''
                    from dataclasses import dataclass

                    ${Prelude.Text.concatSep "\n" params.extraImports}''

        in  ''
            ${imports}


            @dataclass(frozen=True, slots=True)
            class ${params.typeName}:
            ${fieldLines}
            ''

in  Sdk.Sigs.template Params run /\ { Field }
