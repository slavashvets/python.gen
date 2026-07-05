let Deps = ../Deps/package.dhall

let Algebra = ../Algebras/Template.dhall

let Field = { fieldName : Text, fieldType : Text }

-- extraImports are the extra import lines a field type needs (e.g.
-- "from uuid import UUID"). They sit between the dataclass import and the class,
-- separated by one blank line; when empty only the dataclass import is emitted.
let Params = { typeName : Text, extraImports : List Text, fields : List Field }

let run =
      \(params : Params) ->
        let fieldLines =
              Deps.Prelude.Text.concatMapSep
                "\n"
                Field
                ( \(field : Field) ->
                    "    ${field.fieldName}: ${field.fieldType}"
                )
                params.fields

        let imports =
              if    Deps.Prelude.List.null Text params.extraImports
              then  "from dataclasses import dataclass"
              else  ''
                    from dataclasses import dataclass

                    ${Deps.Prelude.Text.concatSep "\n" params.extraImports}''

        in  ''
            ${imports}


            @dataclass(frozen=True, slots=True)
            class ${params.typeName}:
                """Decoding/encoding this composite requires register_types(conn) first.

                Without per-connection registration psycopg returns the value as a
                raw string, which the generated _decode cannot splat into the dataclass.
                """

            ${fieldLines}
            ''

in  Algebra.module Params run /\ { Field }
