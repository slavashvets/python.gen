let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

let TypeKind = < Enum | Composite >

let CustomType =
      { typeName : Text
      , moduleName : Text
      , pgSchema : Text
      , pgName : Text
      , kind : TypeKind
      }

let Params = { customTypes : List CustomType, emitSync : Bool }

let pgNameConstant =
      \(custom : CustomType) -> "_${custom.moduleName}_pg_name"

let makeObjectName =
      \(custom : CustomType) -> "_${custom.moduleName}_make_object"

let makeSequenceName =
      \(custom : CustomType) -> "_${custom.moduleName}_make_sequence"

let metadata =
      \(custom : CustomType) ->
        let pgName = "${custom.pgSchema}.${custom.pgName}"

        let constant = "${pgNameConstant custom} = \"${pgName}\""

        in  merge
              { Enum = constant
              , Composite =
                    constant
                  ++ "\n"
                  ++ "${makeObjectName custom}, ${makeSequenceName custom} = _dataclass_callbacks(_db_types.${custom.typeName})"
              }
              custom.kind

let registration =
      \(awaitKw : Text) ->
      \(custom : CustomType) ->
        let infoName = "${custom.moduleName}_info"

        in  merge
              { Enum =
                    "    ${infoName} = ${awaitKw}EnumInfo.fetch(conn, ${pgNameConstant custom})\n"
                  ++ "    if ${infoName} is None:\n"
                  ++ "        raise LookupError(f\"enum type {${pgNameConstant custom}!r} not found; cannot register it\")\n"
                  ++ "    register_enum(\n"
                  ++ "        ${infoName},\n"
                  ++ "        conn,\n"
                  ++ "        _db_types.${custom.typeName},\n"
                  ++ "        mapping={member: member.value for member in _db_types.${custom.typeName}},\n"
                  ++ "    )"
              , Composite =
                    "    ${infoName} = ${awaitKw}CompositeInfo.fetch(conn, ${pgNameConstant custom})\n"
                  ++ "    if ${infoName} is None:\n"
                  ++ "        raise LookupError(f\"composite type {${pgNameConstant custom}!r} not found; cannot register it\")\n"
                  ++ "    register_composite(\n"
                  ++ "        ${infoName},\n"
                  ++ "        conn,\n"
                  ++ "        _db_types.${custom.typeName},\n"
                  ++ "        make_object=${makeObjectName custom},\n"
                  ++ "        make_sequence=${makeSequenceName custom},\n"
                  ++ "    )"
              }
              custom.kind

let run =
      \(params : Params) ->
        let hasComposites =
              Prelude.List.any
                CustomType
                ( \(custom : CustomType) ->
                    merge { Enum = False, Composite = True } custom.kind
                )
                params.customTypes

        let hasEnums =
              Prelude.List.any
                CustomType
                ( \(custom : CustomType) ->
                    merge { Enum = True, Composite = False } custom.kind
                )
                params.customTypes

        let metadataLines =
              Prelude.Text.concatMapSep
                "\n"
                CustomType
                metadata
                params.customTypes

        let asyncRegistrations =
              Prelude.Text.concatMapSep
                "\n"
                CustomType
                (registration "await ")
                params.customTypes

        let syncRegistrations =
              Prelude.Text.concatMapSep
                "\n"
                CustomType
                (registration "")
                params.customTypes

        let connectionImport =
              if    params.emitSync
              then  "from psycopg import AsyncConnection, Connection"
              else  "from psycopg import AsyncConnection"

        let compositeImports =
              if    hasComposites
              then  ''
                    import keyword
                    from collections.abc import Callable, Sequence
                    from dataclasses import fields, is_dataclass
                    from typing import Any
                    ''
              else  ""

        let adapterImportLines =
                  ( if    hasComposites
                    then  [ "from psycopg.types.composite import CompositeInfo, register_composite" ]
                    else  [] : List Text
                  )
                # ( if    hasEnums
                    then  [ "from psycopg.types.enum import EnumInfo, register_enum" ]
                    else  [] : List Text
                  )

        let adapterImports = Prelude.Text.concatSep "\n" adapterImportLines

        let compositeCallbacks =
              if    hasComposites
              then  ''

                    type _ObjectMaker[T] = Callable[[Sequence[Any], CompositeInfo], T]
                    type _SequenceMaker[T] = Callable[[T, CompositeInfo], Sequence[Any]]


                    def _python_name(name: str) -> str:
                        if keyword.iskeyword(name):
                            return f"{name}_"
                        return name


                    def _dataclass_callbacks[T](cls: type[T]) -> tuple[_ObjectMaker[T], _SequenceMaker[T]]:
                        if not is_dataclass(cls):
                            raise TypeError(f"{cls.__name__} must be a dataclass")

                        model_fields = fields(cls)
                        model_names = tuple(field.name for field in model_fields)

                        def make_object(values: Sequence[Any], info: CompositeInfo) -> T:
                            names = tuple(_python_name(name) for name in info.field_names)
                            assert names == model_names
                            assert len(values) == len(model_fields)
                            return cls(**dict(zip(names, values, strict=True)))

                        def make_sequence(obj: T, info: CompositeInfo) -> Sequence[Any]:
                            names = tuple(_python_name(name) for name in info.field_names)
                            assert names == model_names
                            return tuple(getattr(obj, field.name) for field in model_fields)

                        return make_object, make_sequence
                    ''
              else  ""

        let syncFunction =
              if    params.emitSync
              then  ''



                    def register_types_sync(conn: Connection[object]) -> None:
                    ${syncRegistrations}''
              else  ""

        in  ''
            from __future__ import annotations

            ${compositeImports}
            ${connectionImport}
            ${adapterImports}

            from . import types as _db_types
            ${compositeCallbacks}

            ${metadataLines}


            async def register_types(conn: AsyncConnection[object]) -> None:
            ${asyncRegistrations}${syncFunction}
            ''

in  Sdk.Sigs.template Params run /\ { CustomType, TypeKind }
