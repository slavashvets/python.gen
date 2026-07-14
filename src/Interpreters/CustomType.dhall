let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let PythonNameMapping = ../Structures/PythonNameMapping.dhall

let PythonNamespace = ../Structures/PythonNamespace.dhall

let PyIdent = ../Structures/PyIdent.dhall

let MemberGen = ./Member.dhall

let EnumModule = ../Templates/EnumModule.dhall

let CompositeModule = ../Templates/CompositeModule.dhall

let Config =
      { customTypeNameMappings : List PythonNameMapping.CustomType
      }

let Input = Model.CustomType

let TypeKind = < Enum | Composite >

let Output =
      { modulePath : Text
      , moduleContent : Text
      , typeName : Text
      , moduleName : Text
      , pgSchema : Text
      , pgName : Text
      , kind : TypeKind
      , order : Natural
      , dependencies : List Natural
      , moduleBindings : List PythonNamespace.Binding
      }

let renderExtraImports =
      \(imports : ImportSet.Type) ->
        let datetimeNames =
                  (if imports.date then [ "date" ] else [] : List Text)
                # (if imports.datetime then [ "datetime" ] else [] : List Text)
                # (if imports.time then [ "time" ] else [] : List Text)
                # (if imports.timedelta then [ "timedelta" ] else [] : List Text)

        let datetimeLine =
              if    Prelude.List.null Text datetimeNames
              then  [] : List Text
              else  [ "from datetime import ${Prelude.Text.concatSep
                                                ", "
                                                datetimeNames}" ]

        let customLines =
              Prelude.List.map
                ImportSet.CustomImport
                Text
                ( \(custom : ImportSet.CustomImport) ->
                    "from .${custom.moduleName} import ${custom.className}"
                )
                (ImportSet.sortedCustoms imports)

        in    (if imports.uuid then [ "from uuid import UUID" ] else [] : List Text)
            # datetimeLine
            # ( if    imports.decimal
                then  [ "from decimal import Decimal" ]
                else  [] : List Text
              )
            # ( if    imports.jsonValue
                then  [ "from .._core import JsonValue" ]
                else  [] : List Text
              )
            # customLines

let moduleNamespace =
      \(input : Input) ->
        "custom type module for schema ${Text/show input.pgSchema}, type ${Text/show input.pgName}"

let moduleBinding =
      \(namespace : Text) ->
      \(owner : Text) ->
      \(name : Text) ->
        { namespace
        , owner
        , name
        , remediation = "Choose a different custom type name mapping target"
        }

let enumNamespaceBindings =
      \(input : Input) ->
      \(typeName : Text) ->
        let namespace = moduleNamespace input

        in  [ moduleBinding
                namespace
                "custom type class for schema ${Text/show input.pgSchema}, type ${Text/show input.pgName}"
                typeName
            , moduleBinding namespace "enum base import" "StrEnum"
            ]

let compositeNamespaceBindings =
      \(input : Input) ->
      \(typeName : Text) ->
      \(imports : ImportSet.Type) ->
        let namespace = moduleNamespace input

        let imported =
                ( if    imports.uuid
                  then  [ moduleBinding namespace "UUID primitive import" "UUID" ]
                  else  [] : List PythonNamespace.Binding
                )
              # ( if    imports.datetime
                  then  [ moduleBinding namespace "datetime primitive import" "datetime" ]
                  else  [] : List PythonNamespace.Binding
                )
              # ( if    imports.date
                  then  [ moduleBinding namespace "date primitive import" "date" ]
                  else  [] : List PythonNamespace.Binding
                )
              # ( if    imports.time
                  then  [ moduleBinding namespace "time primitive import" "time" ]
                  else  [] : List PythonNamespace.Binding
                )
              # ( if    imports.timedelta
                  then  [ moduleBinding namespace "timedelta primitive import" "timedelta" ]
                  else  [] : List PythonNamespace.Binding
                )
              # ( if    imports.decimal
                  then  [ moduleBinding namespace "Decimal primitive import" "Decimal" ]
                  else  [] : List PythonNamespace.Binding
                )
              # ( if    imports.jsonValue
                  then  [ moduleBinding namespace "generated core import" "JsonValue" ]
                  else  [] : List PythonNamespace.Binding
                )

        let customImports =
              Prelude.List.map
                ImportSet.CustomImport
                PythonNamespace.Binding
                ( \(custom : ImportSet.CustomImport) ->
                    moduleBinding
                      namespace
                      "custom dependency import \".${custom.moduleName}.${custom.className}\""
                      custom.className
                )
                imports.customTypes

        in    [ moduleBinding
                  namespace
                  "custom type class for schema ${Text/show input.pgSchema}, type ${Text/show input.pgName}"
                  typeName
              , moduleBinding namespace "dataclass decorator import" "dataclass"
              ]
            # imported
            # customImports

let run =
      \(config : Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(input : Input) ->
        let pythonName =
              PythonNameMapping.resolveCustomType
                config.customTypeNameMappings
                { schema = input.pgSchema, name = input.pgName }
                { snakeCase = PyIdent.typeModuleSafeName input.name.inSnakeCase
                , pascalCase = PyIdent.pySafeName input.name.inPascalCase
                }

        let typeName = pythonName.pascalCase

        let moduleName = pythonName.snakeCase

        let modulePath = "types/${moduleName}.py"

        in  merge
              { Enum =
                  \(variants : List Model.EnumVariant) ->
                    let templateVariants =
                          Prelude.List.map
                            Model.EnumVariant
                            EnumModule.Variant
                            ( \(variant : Model.EnumVariant) ->
                                { memberName = variant.name.inScreamingSnakeCase
                                , pgValue = variant.pgName
                                }
                            )
                            variants

                    in  merge
                          { Enum =
                              \(identity : CustomKind.Identity) ->
                                Lude.Compiled.ok
                                  Output
                                  { modulePath
                                  , moduleContent =
                                      EnumModule.run
                                        { typeName
                                        , variants = templateVariants
                                        }
                                  , typeName
                                  , moduleName
                                  , pgSchema = input.pgSchema
                                  , pgName = input.pgName
                                  , kind = TypeKind.Enum
                                  , order = identity.order
                                  , dependencies = [] : List Natural
                                  , moduleBindings =
                                      enumNamespaceBindings input typeName
                                  }
                          , Composite =
                              \(_ : CustomKind.Identity) ->
                                Lude.Compiled.report
                                  Output
                                  [ input.pgName ]
                                  "Custom type lookup kind is inconsistent with enum definition"
                          , Absent =
                              Lude.Compiled.report
                                Output
                                [ input.pgName ]
                                "Custom type not found in project customTypes"
                          }
                          (lookup input.name)
              , Composite =
                  \(members : List Model.Member) ->
                    let compiledMembers
                        : Lude.Compiled.Type (List MemberGen.Output)
                        = Lude.Compiled.traverseList
                            Model.Member
                            MemberGen.Output
                            ( \(m : Model.Member) ->
                                merge
                                  { Primitive =
                                      \(_ : Model.Primitive) ->
                                        MemberGen.run {=} lookup m
                                  , Custom =
                                      \(ref : Model.CustomTypeRef) ->
                                        if    Prelude.Bool.not
                                                (Natural/isZero m.value.dimensionality)
                                        then  Lude.Compiled.report
                                                MemberGen.Output
                                                [ m.pgName, ref.name.inSnakeCase ]
                                                "Custom array fields inside a composite type are not supported"
                                        else  MemberGen.run {=} lookup m
                                  }
                                  m.value.scalar
                            )
                            members

                    let assemble =
                          \(memberOutputs : List MemberGen.Output) ->
                            let combinedImports =
                                  Prelude.List.fold
                                    MemberGen.Output
                                    memberOutputs
                                    ImportSet.Type
                                    ( \(m : MemberGen.Output) ->
                                      \(acc : ImportSet.Type) ->
                                        ImportSet.combine m.imports acc
                                    )
                                    ImportSet.empty

                            let fields =
                                  Prelude.List.map
                                    MemberGen.Output
                                    CompositeModule.Field
                                    ( \(m : MemberGen.Output) ->
                                        { fieldName = m.fieldName
                                        , fieldType = m.pyType
                                        }
                                    )
                                    memberOutputs

                            let dependencies =
                                  Prelude.List.map
                                    ImportSet.CustomImport
                                    Natural
                                    ( \(custom : ImportSet.CustomImport) ->
                                        custom.dedupKey
                                    )
                                    (ImportSet.sortedCustoms combinedImports)

                            in  merge
                                  { Composite =
                                      \(identity : CustomKind.Identity) ->
                                        Lude.Compiled.ok
                                          Output
                                          { modulePath
                                          , moduleContent =
                                              CompositeModule.run
                                                { typeName
                                                , extraImports =
                                                    renderExtraImports
                                                      combinedImports
                                                , fields
                                                }
                                          , typeName
                                          , moduleName
                                          , pgSchema = input.pgSchema
                                          , pgName = input.pgName
                                          , kind = TypeKind.Composite
                                          , order = identity.order
                                          , dependencies
                                          , moduleBindings =
                                              compositeNamespaceBindings
                                              input
                                              typeName
                                              combinedImports
                                          }
                                  , Enum =
                                      \(_ : CustomKind.Identity) ->
                                        Lude.Compiled.report
                                          Output
                                          [ input.pgName ]
                                          "Custom type lookup kind is inconsistent with composite definition"
                                  , Absent =
                                      Lude.Compiled.report
                                        Output
                                        [ input.pgName ]
                                        "Custom type not found in project customTypes"
                                  }
                                  (lookup input.name)

                    in  Lude.Compiled.flatMap
                          (List MemberGen.Output)
                          Output
                          assemble
                          compiledMembers
              , Domain =
                  \(_ : Model.Value) ->
                    Lude.Compiled.report
                      Output
                      [ input.pgName ]
                      "Domain types are not supported; lower to base type in the pgn migration copy"
              }
              input.definition

in  { Input, Output, run }
