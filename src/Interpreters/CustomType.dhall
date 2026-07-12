let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

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

-- moduleName/pgSchema/pgName mirror the input Name/CustomType so Project.dhall's
-- combineOutputs can derive the facade export, types/__init__ export, and the
-- composite/enum registration name from this Output alone (the surviving list
-- after Skip filtering), without a second, separately-threaded List
-- Model.CustomType parameter.
let Output =
      { modulePath : Text
      , moduleContent : Text
      , typeName : Text
      , moduleName : Text
      , pgSchema : Text
      , pgName : Text
      , kind : TypeKind
      }

-- Render the stdlib/runtime imports a composite field type needs, in a fixed
-- order so output stays byte-stable. Reads only the standard flags; nested custom
-- types are out of Wave 2 scope (no composite in the corpus references one).
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

        in    (if imports.uuid then [ "from uuid import UUID" ] else [] : List Text)
            # datetimeLine
            # ( if    imports.decimal
                then  [ "from decimal import Decimal" ]
                else  [] : List Text
              )
            # ( if    imports.jsonValue
                then  [ "from .._runtime import JsonValue" ]
                else  [] : List Text
              )

let run =
      \(config : Config) ->
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

                    in  Lude.Compiled.ok
                          Output
                          { modulePath
                          , moduleContent =
                              EnumModule.run
                                { typeName, variants = templateVariants }
                          , typeName
                          , moduleName
                          , pgSchema = input.pgSchema
                          , pgName = input.pgName
                          , kind = TypeKind.Enum
                          }
              , Composite =
                  \(members : List Model.Member) ->
                    let compiledMembers
                        : Lude.Compiled.Type (List MemberGen.Output)
                        = Lude.Compiled.traverseList
                            Model.Member
                            MemberGen.Output
                            ( \(m : Model.Member) -> MemberGen.run config m )
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

                            in  { modulePath
                                , moduleContent =
                                    CompositeModule.run
                                      { typeName
                                      , extraImports =
                                          renderExtraImports combinedImports
                                      , fields
                                      }
                                , typeName
                                , moduleName
                                , pgSchema = input.pgSchema
                                , pgName = input.pgName
                                , kind = TypeKind.Composite
                                }

                    in  Lude.Compiled.map
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

in  Sdk.Sigs.interpreter Config Input Output run
