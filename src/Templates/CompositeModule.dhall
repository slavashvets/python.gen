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

        -- pg_decode/pg_encode are emitted as literal lines (not a nested
        -- multi-line ''...'' block) because Dhall dedents a multi-line
        -- literal against its OWN source indentation before splicing it into
        -- the outer literal; a nested block loses its intended 4/8-space
        -- class-body indentation. Verified against `dhall text` during design.
        --
        -- Named `pg_decode`/`pg_encode` rather than `_decode`/`_encode`: every
        -- caller lives in a different generated module
        -- (Member.dhall/ParamsMember.dhall), so a leading underscore only
        -- earns a basedpyright strict reportPrivateUsage error, not real
        -- privacy. Plain `decode`/`encode` was tried first and rejected:
        -- EnumModule.dhall's generated class subclasses StrEnum, and `encode`
        -- there collides with `str.encode`'s incompatible signature
        -- (reportIncompatibleMethodOverride). The `pg_` prefix keeps both
        -- generated shapes on one shared name with no collision either way.
        let codecMethods =
                "\n"
              ++ "    @staticmethod\n"
              ++ "    def pg_decode(src: object) -> \"${params.typeName}\":\n"
              ++ "        return ${params.typeName}(*cast(tuple[${fieldTypesJoined}], src))\n"
              ++ "\n"
              ++ "    def pg_encode(self) -> tuple[${fieldTypesJoined}]:\n"
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
                raw string, which the generated pg_decode cannot splat into the dataclass.
                """

            ${fieldLines}
            ${codecMethods}
            ''

in  Sdk.Sigs.template Params run /\ { Field }
