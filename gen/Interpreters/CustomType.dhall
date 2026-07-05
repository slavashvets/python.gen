let Deps = ../Deps/package.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let Algebra = ../Algebras/Interpreter.dhall

let Lude = Deps.Lude

let Prelude = Deps.Prelude

let Model = Deps.Project

let MemberGen = ./Member.dhall

let EnumModule = ../Templates/EnumModule.dhall

let CompositeModule = ../Templates/CompositeModule.dhall

let Input = Model.CustomType

let TypeKind = < Enum | Composite >

let Output =
      { modulePath : Text
      , moduleContent : Text
      , typeName : Text
      , kind : TypeKind
      }

-- Composite fields could in principle reference other custom types, but pgn never
-- nests customs in our corpus and CustomType.run does not receive the project
-- lookup (Project.run threads it only to queries). Resolving any nested custom to
-- Absent makes Member.run fail loudly instead of guessing a type.
let nestedLookup
    : CustomKind.Lookup
    = \(_ : Model.Name) -> CustomKind.TypeKind.Absent

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
      \(config : Algebra.Config) ->
      \(input : Input) ->
        let typeName = input.name.inPascalCase

        let modulePath = "types/${input.name.inSnakeCase}.py"

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
                          , kind = TypeKind.Enum
                          }
              , Composite =
                  \(members : List Model.Member) ->
                    let compiledMembers
                        : Lude.Compiled.Type (List MemberGen.Output)
                        = Lude.Compiled.traverseList
                            Model.Member
                            MemberGen.Output
                            ( \(m : Model.Member) ->
                                MemberGen.run config nestedLookup m
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

                            in  { modulePath
                                , moduleContent =
                                    CompositeModule.run
                                      { typeName
                                      , extraImports =
                                          renderExtraImports combinedImports
                                      , fields
                                      }
                                , typeName
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

in  { Input, Output, TypeKind, run }
