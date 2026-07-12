let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

let Variant = { memberName : Text, pgValue : Text }

let Params = { typeName : Text, variants : List Variant }

let run =
      \(params : Params) ->
        -- pgValue is interpolated into a single-line double-quoted Python literal; a
        -- label may legally contain a backslash, quote, or control character, so
        -- escape them to keep the literal valid and value-equal to the DB label.
        -- Order is load-bearing: backslash first (so the escapes added below are not
        -- re-escaped), then the control chars, then the closing quote.
        let escapeLabel
            : Text -> Text
            = \(raw : Text) ->
                Prelude.Function.composeList
                  Text
                  [ Prelude.Text.replace "\\" "\\\\"
                  , Prelude.Text.replace "\r" "\\r"
                  , Prelude.Text.replace "\n" "\\n"
                  , Prelude.Text.replace "\t" "\\t"
                  , Prelude.Text.replace "\"" "\\\""
                  ]
                  raw

        let memberLines =
              Prelude.Text.concatMapSep
                "\n"
                Variant
                ( \(variant : Variant) ->
                    "    ${variant.memberName} = \"${escapeLabel variant.pgValue}\""
                )
                params.variants

        -- pg_decode/pg_encode, not decode/encode or _decode/_encode: see
        -- CompositeModule.dhall's codecMethods comment. The `pg_` prefix
        -- matters here specifically — this class subclasses StrEnum, so a
        -- plain `encode` would override `str.encode`'s incompatible
        -- signature (reportIncompatibleMethodOverride).
        let codecMethods =
                "\n"
              ++ "    @staticmethod\n"
              ++ "    def pg_decode(src: object) -> \"${params.typeName}\":\n"
              ++ "        return ${params.typeName}(cast(str, src))\n"
              ++ "\n"
              ++ "    def pg_encode(self) -> \"${params.typeName}\":\n"
              ++ "        return self"

        in  ''
            from enum import StrEnum
            from typing import cast


            class ${params.typeName}(StrEnum):
            ${memberLines}
            ${codecMethods}
            ''

in  Sdk.Sigs.template Params run /\ { Variant }
