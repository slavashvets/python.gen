let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let MemberGen = ./Member.dhall

let EnumModule = ../Templates/EnumModule.dhall

let CompositeModule = ../Templates/CompositeModule.dhall

let Config =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
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

let run =
      \(config : Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(input : Input) ->
        let typeName = input.name.inPascalCase

        let moduleName = input.name.inSnakeCase

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
                              \(order : Natural) ->
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
                                  , order
                                  , dependencies = [] : List Natural
                                  }
                          , Composite =
                              \ ( _
                                : { fields : List CustomKind.CompositeField
                                  , order : Natural
                                  }
                                ) ->
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
                                        MemberGen.run config lookup m
                                  , Custom =
                                      \(name : Model.Name) ->
                                        Prelude.Optional.fold
                                          Model.ArraySettings
                                          m.value.arraySettings
                                          (Lude.Compiled.Type MemberGen.Output)
                                          ( \(_ : Model.ArraySettings) ->
                                              Lude.Compiled.report
                                                MemberGen.Output
                                                [ m.pgName, name.inSnakeCase ]
                                                "Custom array fields inside a composite type are not supported"
                                          )
                                          (MemberGen.run config lookup m)
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
                                      \ ( composite
                                        : { fields :
                                              List CustomKind.CompositeField
                                          , order : Natural
                                          }
                                        ) ->
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
                                          , order = composite.order
                                          , dependencies
                                          }
                                  , Enum =
                                      \(_ : Natural) ->
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
