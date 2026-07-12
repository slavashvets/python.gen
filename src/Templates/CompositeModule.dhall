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

        let fieldCount = Prelude.List.length Field params.fields

        let fieldTypesJoined =
              Prelude.Text.concatMapSep
                ", "
                Field
                (\(field : Field) -> field.fieldType)
                params.fields

        let selfFieldsJoined =
              Prelude.Text.concatMapSep
                ", "
                Field
                (\(field : Field) -> "self.${field.fieldName}")
                params.fields

        -- Python only treats trailing-comma parens as a 1-tuple; concatMapSep
        -- never emits an internal comma for a single-element list, so force one
        -- here. Mirrors ParamsMember.dhall's existing compositeBind trick.
        let encodeTupleExpr =
              if    Prelude.Natural.equal fieldCount 1
              then  "(${selfFieldsJoined},)"
              else  "(${selfFieldsJoined})"

        -- _decode/_encode are emitted as literal lines (not a nested multi-line
        -- ''...'' block) because Dhall dedents a multi-line literal against its
        -- OWN source indentation before splicing it into the outer literal; a
        -- nested block loses its intended 4/8-space class-body indentation.
        -- Verified against `dhall text` during design.
        let codecMethods =
                "\n"
              ++ "    @staticmethod\n"
              ++ "    def _decode(src: object) -> \"${params.typeName}\":\n"
              ++ "        return ${params.typeName}(*cast(tuple[${fieldTypesJoined}], src))\n"
              ++ "\n"
              ++ "    def _encode(self) -> tuple[${fieldTypesJoined}]:\n"
              ++ "        return ${encodeTupleExpr}"

        let imports =
              if    Prelude.List.null Text params.extraImports
              then  "from dataclasses import dataclass\nfrom typing import cast"
              else  ''
                    from dataclasses import dataclass
                    from typing import cast

                    ${Prelude.Text.concatSep "\n" params.extraImports}''

        in  ''
            ${imports}


            @dataclass(frozen=True, slots=True)
            class ${params.typeName}:
                """Decoding/encoding this composite requires register_types(conn) first.

                Without per-connection registration psycopg returns the value as a
                raw string, which the generated _decode cannot splat into the dataclass.
                """

            ${fieldLines}
            ${codecMethods}
            ''

in  Sdk.Sigs.template Params run /\ { Field }
