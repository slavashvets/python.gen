let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let CustomKind = ../Structures/CustomKind.dhall

let PyIdent = ../Structures/PyIdent.dhall

let QueryGen = ./Query.dhall

let CustomTypeGen = ./CustomType.dhall

let CoreModule = ../Templates/CoreModule.dhall

let RuntimeModule = ../Templates/RuntimeModule.dhall

let InitModule = ../Templates/InitModule.dhall

let TypesInit = ../Templates/TypesInit.dhall

let RegisterModule = ../Templates/RegisterModule.dhall

let FacadeModule = ../Templates/FacadeModule.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let PythonNameMapping = ../Structures/PythonNameMapping.dhall

let PythonNamespace = ../Structures/PythonNamespace.dhall

let Report = { path : List Text, message : Text }

-- The generator's public Config: every field is independently Optional, so a
-- project may omit the whole `config:` block or any subset of its keys.
-- `run` below resolves the fallbacks itself (packageName from the project
-- name, sync emission off, onUnsupported Fail); there is no separate config type
-- or resolve step between package.dhall and here.
let Config =
      { packageName : Optional Text
      , emitSync : Optional Bool
      , onUnsupported : Optional OnUnsupported.Mode
      , queryNameMappings : Optional (List PythonNameMapping.Query)
      , customTypeNameMappings : Optional (List PythonNameMapping.CustomType)
      }

-- The root resolves every public option once. Query receives only emitSync and
-- its mappings, while CustomType receives only its mappings. Lower interpreters
-- use empty configs except for Result's caller-supplied rowClassName.
let ResolvedConfig =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
      , queryNameMappings : List PythonNameMapping.Query
      , customTypeNameMappings : List PythonNameMapping.CustomType
      }

let Input = Model.Project

let Output = Lude.Files.Type

let QueryMappingState =
      { seen : List Text, error : Optional Report }

let CustomTypeMappingState =
      { seen : List PythonNameMapping.CustomTypeSource
      , error : Optional Report
      }

let CustomTypeIdentity =
      { contractName : Text, source : PythonNameMapping.CustomTypeSource }

let CustomTypeIdentityState =
      { seen : List CustomTypeIdentity, error : Optional Report }

let finishMappingValidation =
      \(stateError : Optional Report) ->
        Prelude.Optional.fold
          Report
          stateError
          (Lude.Compiled.Type {})
          (\(report : Report) -> (Lude.Compiled.Type {}).Err report)
          (Lude.Compiled.ok {} {=})

let validateCustomTypeIdentities =
      \(customTypes : List Model.CustomType) ->
        let step =
              \(customType : Model.CustomType) ->
              \(state : CustomTypeIdentityState) ->
                Prelude.Optional.fold
                  Report
                  state.error
                  CustomTypeIdentityState
                  (\(_ : Report) -> state)
                  ( let contractName = customType.name.inSnakeCase

                    let previous =
                          List/fold
                            CustomTypeIdentity
                            state.seen
                            (Optional PythonNameMapping.CustomTypeSource)
                            ( \(identity : CustomTypeIdentity) ->
                              \(found : Optional PythonNameMapping.CustomTypeSource) ->
                                if    Text/equal
                                        identity.contractName
                                        contractName
                                then  Some identity.source
                                else  found
                            )
                            (None PythonNameMapping.CustomTypeSource)

                    let error =
                          Prelude.Optional.fold
                            PythonNameMapping.CustomTypeSource
                            previous
                            (Optional Report)
                            ( \(source : PythonNameMapping.CustomTypeSource) ->
                                Some
                                  { path = [ "customTypes", contractName ]
                                  , message =
                                          "Ambiguous unqualified custom type identity "
                                      ++  Text/show contractName
                                      ++  ": schema "
                                      ++  Text/show source.schema
                                      ++  ", type "
                                      ++  Text/show source.name
                                      ++  " and schema "
                                      ++  Text/show customType.pgSchema
                                      ++  ", type "
                                      ++  Text/show customType.pgName
                                      ++  " share one contract Name. The upstream contract must preserve a distinct schema-qualified custom identifier; Python mappings cannot recover it"
                                  }
                            )
                            (None Report)

                    let identity =
                          { contractName
                          , source =
                              { schema = customType.pgSchema
                              , name = customType.pgName
                              }
                          }

                    in  { seen = state.seen # [ identity ], error }
                  )

        let state =
              List/fold
                Model.CustomType
                customTypes
                CustomTypeIdentityState
                step
                { seen = [] : List CustomTypeIdentity
                , error = None Report
                }

        in  finishMappingValidation state.error

let validateQueryMappings =
      \(mappings : List PythonNameMapping.Query) ->
      \(queries : List Model.Query) ->
        let step =
              \(mapping : PythonNameMapping.Query) ->
              \(state : QueryMappingState) ->
                Prelude.Optional.fold
                  Report
                  state.error
                  QueryMappingState
                  (\(_ : Report) -> state)
                  ( let duplicate =
                          Prelude.List.any
                            Text
                            (\(source : Text) -> Text/equal source mapping.source)
                            state.seen

                    let known =
                          Prelude.List.any
                            Model.Query
                            ( \(query : Model.Query) ->
                                Text/equal query.name.inSnakeCase mapping.source
                            )
                            queries

                    let snakeIsExact =
                          PyIdent.isSnakeIdentifier mapping.target.snakeCase
                          && Text/equal
                              (PyIdent.querySafeName mapping.target.snakeCase)
                              mapping.target.snakeCase

                    let pascalIsExact =
                          PyIdent.isPascalIdentifier mapping.target.pascalCase
                          && Text/equal
                              (PyIdent.pySafeName mapping.target.pascalCase)
                              mapping.target.pascalCase

                    let error =
                          if    duplicate
                          then  Some
                                { path =
                                    [ "config"
                                    , "queryNameMappings"
                                    , mapping.source
                                    ]
                                , message =
                                    "Duplicate query name mapping source \"${mapping.source}\""
                                }
                          else  if Prelude.Bool.not known
                          then  Some
                                { path =
                                    [ "config"
                                    , "queryNameMappings"
                                    , mapping.source
                                    ]
                                , message =
                                    "Unknown query name mapping source \"${mapping.source}\""
                                }
                          else  if Prelude.Bool.not snakeIsExact
                          then  Some
                                { path =
                                    [ "config"
                                    , "queryNameMappings"
                                    , mapping.source
                                    , "target"
                                    , "snakeCase"
                                    ]
                                , message =
                                    "Mapped query snakeCase must start with a lowercase ASCII letter, then contain only lowercase ASCII letters, digits, or underscores, and must not be reserved"
                                }
                          else  if Prelude.Bool.not pascalIsExact
                          then  Some
                                { path =
                                    [ "config"
                                    , "queryNameMappings"
                                    , mapping.source
                                    , "target"
                                    , "pascalCase"
                                    ]
                                , message =
                                    "Mapped query pascalCase must start with an uppercase ASCII letter, then contain only ASCII letters or digits, and must not be reserved"
                                }
                          else  None Report

                    in  { seen = state.seen # [ mapping.source ], error }
                  )

        let state =
              List/fold
                PythonNameMapping.Query
                mappings
                QueryMappingState
                step
                { seen = [] : List Text, error = None Report }

        in  finishMappingValidation state.error

let validateCustomTypeMappings =
      \(mappings : List PythonNameMapping.CustomType) ->
      \(customTypes : List Model.CustomType) ->
        let sameSource =
              \(left : PythonNameMapping.CustomTypeSource) ->
              \(right : PythonNameMapping.CustomTypeSource) ->
                Text/equal left.schema right.schema
                && Text/equal left.name right.name

        let step =
              \(mapping : PythonNameMapping.CustomType) ->
              \(state : CustomTypeMappingState) ->
                Prelude.Optional.fold
                  Report
                  state.error
                  CustomTypeMappingState
                  (\(_ : Report) -> state)
                  ( let duplicate =
                          Prelude.List.any
                            PythonNameMapping.CustomTypeSource
                            (sameSource mapping.source)
                            state.seen

                    let known =
                          Prelude.List.any
                            Model.CustomType
                            ( \(customType : Model.CustomType) ->
                                Text/equal
                                  customType.pgSchema
                                  mapping.source.schema
                                && Text/equal
                                    customType.pgName
                                    mapping.source.name
                            )
                            customTypes

                    let snakeIsExact =
                          PyIdent.isSnakeIdentifier mapping.target.snakeCase
                          && Text/equal
                              ( PyIdent.typeModuleSafeName
                                  mapping.target.snakeCase
                              )
                              mapping.target.snakeCase

                    let pascalIsExact =
                          PyIdent.isPascalIdentifier mapping.target.pascalCase
                          && Text/equal
                              (PyIdent.pySafeName mapping.target.pascalCase)
                              mapping.target.pascalCase

                    let source =
                          "${mapping.source.schema}.${mapping.source.name}"

                    let error =
                          if    duplicate
                          then  Some
                                { path =
                                    [ "config"
                                    , "customTypeNameMappings"
                                    , source
                                    ]
                                , message =
                                    "Duplicate custom type name mapping source \"${source}\""
                                }
                          else  if Prelude.Bool.not known
                          then  Some
                                { path =
                                    [ "config"
                                    , "customTypeNameMappings"
                                    , source
                                    ]
                                , message =
                                    "Unknown custom type name mapping source \"${source}\""
                                }
                          else  if Prelude.Bool.not snakeIsExact
                          then  Some
                                { path =
                                    [ "config"
                                    , "customTypeNameMappings"
                                    , source
                                    , "target"
                                    , "snakeCase"
                                    ]
                                , message =
                                    "Mapped custom type snakeCase must start with a lowercase ASCII letter, then contain only lowercase ASCII letters, digits, or underscores, and must not be reserved"
                                }
                          else  if Prelude.Bool.not pascalIsExact
                          then  Some
                                { path =
                                    [ "config"
                                    , "customTypeNameMappings"
                                    , source
                                    , "target"
                                    , "pascalCase"
                                    ]
                                , message =
                                    "Mapped custom type pascalCase must start with an uppercase ASCII letter, then contain only ASCII letters or digits, and must not be reserved"
                                }
                          else  None Report

                    in  { seen = state.seen # [ mapping.source ], error }
                  )

        let state =
              List/fold
                PythonNameMapping.CustomType
                mappings
                CustomTypeMappingState
                step
                { seen = [] : List PythonNameMapping.CustomTypeSource
                , error = None Report
                }

        in  finishMappingValidation state.error

let validateLocalNamespaces =
      \(queries : List Model.Query) ->
      \(customTypes : List Model.CustomType) ->
        let validateQuery =
              \(query : Model.Query) ->
                let querySource = Text/show query.name.inSnakeCase

                let parameterBindings =
                      Prelude.List.map
                        Model.Member
                        PythonNamespace.Binding
                        ( \(parameter : Model.Member) ->
                            { namespace =
                                "parameters for query ${querySource}"
                            , owner =
                                "query parameter ${Text/show parameter.pgName}"
                            , name =
                                PyIdent.parameterSafeName
                                  parameter.name.inSnakeCase
                            , remediation = "Rename one SQL placeholder"
                            }
                        )
                        query.params

                let resultColumns =
                      merge
                        { Void = [] : List Model.Member
                        , RowsAffected = [] : List Model.Member
                        , Rows =
                            \(rows : Model.ResultRows) ->
                              Prelude.NonEmpty.toList
                                Model.Member
                                rows.columns
                        }
                        query.result

                let resultBindings =
                      Prelude.List.map
                        Model.Member
                        PythonNamespace.Binding
                        ( \(column : Model.Member) ->
                            { namespace =
                                "result fields for query ${querySource}"
                            , owner =
                                "result column ${Text/show column.pgName}"
                            , name =
                                PyIdent.pySafeName column.name.inSnakeCase
                            , remediation = "Rename one SQL result alias"
                            }
                        )
                        resultColumns

                in  PythonNamespace.validate
                      (parameterBindings # resultBindings)

        let validateCustomType =
              \(customType : Model.CustomType) ->
                let customSource =
                      "schema ${Text/show customType.pgSchema}, type ${Text/show customType.pgName}"

                let bindings =
                      merge
                        { Composite =
                            \(members : List Model.Member) ->
                              Prelude.List.map
                                Model.Member
                                PythonNamespace.Binding
                                ( \(member : Model.Member) ->
                                    { namespace =
                                        "fields for custom type ${customSource}"
                                    , owner =
                                        "composite field ${Text/show member.pgName}"
                                    , name =
                                        PyIdent.pySafeName
                                          member.name.inSnakeCase
                                    , remediation =
                                        "Rename one PostgreSQL composite field"
                                    }
                                )
                                members
                        , Enum =
                            \(variants : List Model.EnumVariant) ->
                              Prelude.List.map
                                Model.EnumVariant
                                PythonNamespace.Binding
                                ( \(variant : Model.EnumVariant) ->
                                    { namespace =
                                        "enum members for custom type ${customSource}"
                                    , owner =
                                        "enum label ${Text/show variant.pgName}"
                                    , name =
                                        PyIdent.pySafeName
                                          variant.name.inScreamingSnakeCase
                                    , remediation =
                                        "Rename one PostgreSQL enum label"
                                    }
                                )
                                variants
                        , Domain =
                            \(_ : Model.Value) ->
                              [] : List PythonNamespace.Binding
                        }
                        customType.definition

                in  PythonNamespace.validate bindings

        let queryValidation =
              Lude.Compiled.map
                (List {})
                {}
                (\(_ : List {}) -> {=})
                ( Lude.Compiled.traverseList
                    Model.Query
                    {}
                    validateQuery
                    queries
                )

        let customTypeValidation =
              Lude.Compiled.map
                (List {})
                {}
                (\(_ : List {}) -> {=})
                ( Lude.Compiled.traverseList
                    Model.CustomType
                    {}
                    validateCustomType
                    customTypes
                )

        in  Lude.Compiled.flatMap
              {}
              {}
              (\(_ : {}) -> customTypeValidation)
              queryValidation

-- Header of every emitted .py file. The marker truthfully warns that another
-- generation replaces manual changes. The SPDX pair (REUSE convention)
-- licenses the emitted file itself as MIT-0.
let generatedHeader =
      ''
      # @generated by python.gen (pGenie); regeneration overwrites manual changes.
      # SPDX-FileCopyrightText: 2026 Viacheslav Shvets
      # SPDX-License-Identifier: MIT-0

      ''

let withHeader =
      \(file : Lude.File.Type) ->
        { path = file.path, content = generatedHeader ++ file.content }

let IndexedCustomType = { index : Natural, value : Model.CustomType }

let LookupKind = < Composite | Enum | Domain >

let LookupEntry =
      { contractName : Text
      , kind : LookupKind
      , identity : CustomKind.Identity
      }

let ResolvedCustomType =
      { value : Model.CustomType, lookupEntry : LookupEntry }

let resolveCustomTypes =
      \(nameMappings : List PythonNameMapping.CustomType) ->
      \(customTypes : List Model.CustomType) ->
        Prelude.List.map
          IndexedCustomType
          ResolvedCustomType
          ( \(entry : IndexedCustomType) ->
              let customType = entry.value

              let pythonName =
                    PythonNameMapping.resolveCustomType
                      nameMappings
                      { schema = customType.pgSchema, name = customType.pgName }
                      { snakeCase =
                          PyIdent.typeModuleSafeName
                            customType.name.inSnakeCase
                      , pascalCase = PyIdent.pySafeName customType.name.inPascalCase
                      }

              let identity =
                    { className = pythonName.pascalCase
                    , moduleName = pythonName.snakeCase
                    , order = entry.index
                    }

              let kind =
                    merge
                      { Composite = \(_ : List Model.Member) -> LookupKind.Composite
                      , Enum = \(_ : List Model.EnumVariant) -> LookupKind.Enum
                      , Domain = \(_ : Model.Value) -> LookupKind.Domain
                      }
                      customType.definition

              in  { value = customType
                  , lookupEntry =
                      { contractName = customType.name.inSnakeCase
                      , kind
                      , identity
                      }
                  }
          )
          (Prelude.List.indexed Model.CustomType customTypes)

let lookupEntries =
      \(customTypes : List ResolvedCustomType) ->
        Prelude.List.map
          ResolvedCustomType
          LookupEntry
          (\(customType : ResolvedCustomType) -> customType.lookupEntry)
          customTypes

let buildLookup =
      \(entries : List LookupEntry) ->
        Prelude.List.fold
          LookupEntry
          entries
          CustomKind.Lookup
          ( \(entry : LookupEntry) ->
            \(rest : CustomKind.Lookup) ->
              \(name : Model.Name) ->
              -- Text/equal is a pgn embedded-Dhall builtin. The upstream exit is
              -- a stable custom kind or id on Scalar.Custom.
                if    Text/equal name.inSnakeCase entry.contractName
                then  merge
                        { Composite =
                            CustomKind.TypeKind.Composite entry.identity
                        , Enum = CustomKind.TypeKind.Enum entry.identity
                        , Domain = CustomKind.TypeKind.Absent
                        }
                        entry.kind
                else  rest name
          )
          (\(_ : Model.Name) -> CustomKind.TypeKind.Absent)

let sameOrder =
      \(left : Natural) ->
      \(right : Natural) ->
        Natural/isZero (Natural/subtract left right)
        && Natural/isZero (Natural/subtract right left)

let containsOrder =
      \(order : Natural) ->
      \(customTypes : List CustomTypeGen.Output) ->
        Prelude.List.any
          CustomTypeGen.Output
          (\(custom : CustomTypeGen.Output) -> sameOrder order custom.order)
          customTypes

let dependenciesReady =
      \(emitted : List CustomTypeGen.Output) ->
      \(custom : CustomTypeGen.Output) ->
        Prelude.Bool.not
          ( Prelude.List.any
              Natural
              (\(dependency : Natural) -> Prelude.Bool.not (containsOrder dependency emitted))
              custom.dependencies
          )

let RegistrationState =
      { emitted : List CustomTypeGen.Output
      , remaining : List CustomTypeGen.Output
      }

let registrationOrder =
      \(customTypes : List CustomTypeGen.Output) ->
        let enums =
              Prelude.List.filter
                CustomTypeGen.Output
                ( \(custom : CustomTypeGen.Output) ->
                    merge { Enum = True, Composite = False } custom.kind
                )
                customTypes

        let composites =
              Prelude.List.filter
                CustomTypeGen.Output
                ( \(custom : CustomTypeGen.Output) ->
                    merge { Enum = False, Composite = True } custom.kind
                )
                customTypes

        let pass =
              \(state : RegistrationState) ->
                let ready =
                      Prelude.List.filter
                        CustomTypeGen.Output
                        (dependenciesReady state.emitted)
                        state.remaining

                let blocked =
                      Prelude.List.filter
                        CustomTypeGen.Output
                        ( \(custom : CustomTypeGen.Output) ->
                            Prelude.Bool.not
                              (dependenciesReady state.emitted custom)
                        )
                        state.remaining

                in  { emitted = state.emitted # ready, remaining = blocked }

        let ordered =
              Natural/fold
                (Prelude.List.length CustomTypeGen.Output customTypes)
                RegistrationState
                pass
                { emitted = enums, remaining = composites }

        let unresolved =
              Prelude.Text.concatMapSep
                ", "
                CustomTypeGen.Output
                ( \(custom : CustomTypeGen.Output) ->
                    "${custom.pgSchema}.${custom.pgName}"
                )
                ordered.remaining

        in  if Prelude.List.null CustomTypeGen.Output ordered.remaining
            then  Lude.Compiled.ok (List CustomTypeGen.Output) ordered.emitted
            else  Lude.Compiled.report
                    (List CustomTypeGen.Output)
                    [ "register_types" ]
                    "Unresolved or cyclic custom type dependencies: ${unresolved}"

let validateProjectNamespaces =
      \(config : ResolvedConfig) ->
      \(queries : List QueryGen.Output) ->
      \(customTypes : List CustomTypeGen.Output) ->
        let mappingRemediation =
              "Rename the source or configure a typed name mapping"

        let queryOwner =
              \(query : QueryGen.Output) ->
                "query \"${query.sourceName}\" (${query.sourcePath})"

        let queryModuleBindings =
              Prelude.List.map
                QueryGen.Output
                PythonNamespace.Binding
                ( \(query : QueryGen.Output) ->
                    { namespace = "generated statement modules"
                    , owner = queryOwner query
                    , name = query.functionName
                    , remediation = mappingRemediation
                    }
                )
                queries

        let typeModuleBindings =
              Prelude.List.map
                CustomTypeGen.Output
                PythonNamespace.Binding
                ( \(customType : CustomTypeGen.Output) ->
                    { namespace = "generated custom type modules"
                    , owner =
                        "custom type \"${customType.pgSchema}.${customType.pgName}\""
                    , name = customType.moduleName
                    , remediation = mappingRemediation
                    }
                )
                customTypes

        let coreFacadeBindings =
              [ { namespace = "package facade"
                , owner = "generated core symbol JsonValue"
                , name = "JsonValue"
                , remediation = mappingRemediation
                }
              , { namespace = "package facade"
                , owner = "generated core symbol NoRowError"
                , name = "NoRowError"
                , remediation = mappingRemediation
                }
              ] : List PythonNamespace.Binding

        let syncFacadeBindings =
              if    config.emitSync
              then  [ { namespace = "package facade"
                      , owner = "generated sync facade"
                      , name = "sync"
                      , remediation = mappingRemediation
                      }
                    ]
              else  [] : List PythonNamespace.Binding

        let registrationFacadeBindings =
              if    Prelude.List.null CustomTypeGen.Output customTypes
              then  [] : List PythonNamespace.Binding
              else  [ { namespace = "package facade"
                      , owner = "generated type registration function"
                      , name = "register_types"
                      , remediation = mappingRemediation
                      }
                    ]

        let queryFacadeBindings =
              Prelude.List.concatMap
                QueryGen.Output
                PythonNamespace.Binding
                ( \(query : QueryGen.Output) ->
                    let functionBinding =
                          { namespace = "package facade"
                          , owner = queryOwner query
                          , name = query.functionName
                          , remediation = mappingRemediation
                          }

                    let rowBindings =
                          Prelude.Optional.fold
                            Text
                            query.rowClassName
                            (List PythonNamespace.Binding)
                            ( \(rowClassName : Text) ->
                                [ { namespace = "package facade"
                                  , owner =
                                      "Row class from ${queryOwner query}"
                                  , name = rowClassName
                                  , remediation = mappingRemediation
                                  }
                                ]
                            )
                            ([] : List PythonNamespace.Binding)

                    in  [ functionBinding ] # rowBindings
                )
                queries

        let typeFacadeBindings =
              Prelude.List.map
                CustomTypeGen.Output
                PythonNamespace.Binding
                ( \(customType : CustomTypeGen.Output) ->
                    { namespace = "package facade"
                    , owner =
                        "custom type \"${customType.pgSchema}.${customType.pgName}\""
                    , name = customType.typeName
                    , remediation = mappingRemediation
                    }
                )
                customTypes

        -- validate freezes a right-folded state, so groups are supplied in
        -- reverse diagnostic priority. Module/file collisions remain the
        -- primary cause when the same pair would also collide in a facade.
        let projectValidation =
              PythonNamespace.validate
                (   typeFacadeBindings
                  # queryFacadeBindings
                  # registrationFacadeBindings
                  # syncFacadeBindings
                  # coreFacadeBindings
                  # typeModuleBindings
                  # queryModuleBindings
                )

        -- A module-name collision is fatal in Fail and Skip alike. These
        -- bindings travel through CustomType.Output so Skip's support probe
        -- cannot mistake a naming error for an unsupported PostgreSQL shape.
        let moduleValidation =
              Lude.Compiled.map
                (List {})
                {}
                (\(_ : List {}) -> {=})
                ( Lude.Compiled.traverseList
                    CustomTypeGen.Output
                    {}
                    ( \(customType : CustomTypeGen.Output) ->
                        PythonNamespace.validate
                          customType.moduleBindings
                    )
                    customTypes
                )

        in  Lude.Compiled.flatMap
              {}
              {}
              (\(_ : {}) -> projectValidation)
              moduleValidation

let combineOutputs =
      \(config : ResolvedConfig) ->
      \(input : Input) ->
      -- Already the post-Skip-filter surviving set (see `run`); equal to
      -- input.queries' compiled outputs verbatim when nothing was skipped
      -- (including every Fail-mode run, since Fail never drops anything).
      -- Facade/statement/row entries are built from this, not input.queries,
      -- so a skipped query leaves no dangling export.
      \(queries : List QueryGen.Output) ->
      -- Same as above, but for customTypes. Facade/typesInit/register
      -- entries are built from this, not input.customTypes, so a skipped
      -- type leaves no dangling export.
      \(customTypes : List CustomTypeGen.Output) ->
      -- Same compiled custom types in dependency-first order, used only by the
      -- shared register module. File and facade order remains project order.
      \(registrationTypes : List CustomTypeGen.Output) ->
        -- The generator emits the _generated subtree plus the package-root
        -- __init__.py facade. The rest of the shell (pyproject.toml, py.typed) is
        -- hand-written and committed once, never overwritten by generation.
        let packagePrefix = "src/${config.importName}/"

        let srcPrefix = packagePrefix ++ "_generated/"

        let topInit =
              { path = srcPrefix ++ "__init__.py"
              , content =
                  InitModule.run
                    { docstring =
                        "Generated database client for ${config.packageName}."
                    }
              }

        let facadeStatements =
              Prelude.List.map
                QueryGen.Output
                FacadeModule.StatementExport
                ( \(query : QueryGen.Output) ->
                    { functionName = query.functionName
                    , rowClassName = query.rowClassName
                    }
                )
                queries

        let facadeTypes =
              Prelude.List.map
                CustomTypeGen.Output
                FacadeModule.TypeExport
                ( \(ct : CustomTypeGen.Output) ->
                    { moduleName = ct.moduleName, className = ct.typeName }
                )
                customTypes

        -- Surface-agnostic; performs no I/O, so exactly one copy is emitted
        -- regardless of surface. Both runtime bodies re-export from it.
        let coreModule =
              { path = srcPrefix ++ "_core.py", content = CoreModule.run {=} }

        let runtimeModule =
              { path = srcPrefix ++ "_runtime.py"
              , content = RuntimeModule.run {=}
              }

        let syncRuntimeFiles =
              if    config.emitSync
              then  [ { path = srcPrefix ++ "sync/_runtime.py"
                      , content = RuntimeModule.runSync {=}
                      }
                    ]
              else  [] : List Lude.File.Type

        let statementsInit =
              { path = srcPrefix ++ "statements/__init__.py"
              , content =
                  InitModule.run { docstring = "Generated SQL statements." }
              }

        let statementFiles =
              Prelude.List.map
                QueryGen.Output
                Lude.File.Type
                ( \(query : QueryGen.Output) ->
                    { path = srcPrefix ++ query.modulePath
                    , content = query.content
                    }
                )
                queries

        let typeFiles =
              Prelude.List.map
                CustomTypeGen.Output
                Lude.File.Type
                ( \(ct : CustomTypeGen.Output) ->
                    { path = srcPrefix ++ ct.modulePath
                    , content = ct.moduleContent
                    }
                )
                customTypes

        let typesInitExports =
              Prelude.List.map
                CustomTypeGen.Output
                TypesInit.Export
                (\(ct : CustomTypeGen.Output) -> { moduleName = ct.moduleName, typeName = ct.typeName })
                customTypes

        let typesInitFiles =
              if    Prelude.List.null CustomTypeGen.Output customTypes
              then  [] : List Lude.File.Type
              else  [ { path = srcPrefix ++ "types/__init__.py"
                      , content = TypesInit.run { exports = typesInitExports }
                      }
                    ]

        let hasCustomRegistration =
              Prelude.Bool.not
                (Prelude.List.null CustomTypeGen.Output registrationTypes)

        let registrationEntries =
              Prelude.List.map
                CustomTypeGen.Output
                RegisterModule.CustomType
                ( \(custom : CustomTypeGen.Output) ->
                    { typeName = custom.typeName
                    , moduleName = custom.moduleName
                    , pgSchema = custom.pgSchema
                    , pgName = custom.pgName
                    , kind = custom.kind
                    }
                )
                registrationTypes

        let registerFiles =
              if    hasCustomRegistration
              then  [ { path = srcPrefix ++ "_register.py"
                      , content =
                          RegisterModule.run
                            { customTypes = registrationEntries
                            , emitSync = config.emitSync
                            }
                      }
                    ]
              else  [] : List Lude.File.Type

        let registrationSource =
              if    hasCustomRegistration
              then  Some "register_types"
              else  None Text

        let facade =
              { path = packagePrefix ++ "__init__.py"
              , content =
                  FacadeModule.run
                    { statements = facadeStatements
                    , types = facadeTypes
                    , generatedPrefix = "._generated"
                    , functionSuffix = ""
                    , registrationSource
                    , includeSyncModule = config.emitSync
                    }
              }

        let syncFacadeFiles =
              if    config.emitSync
              then  [ { path = packagePrefix ++ "sync/__init__.py"
                      , content =
                          FacadeModule.run
                            { statements = facadeStatements
                            , types = facadeTypes
                            , generatedPrefix = ".._generated"
                            , functionSuffix = "_sync"
                            , registrationSource =
                                if    hasCustomRegistration
                                then  Some "register_types_sync"
                                else  None Text
                            , includeSyncModule = False
                            }
                      }
                    ]
              else  [] : List Lude.File.Type

        let staticFiles =
              [ facade, topInit, coreModule, runtimeModule, statementsInit ]
              # syncFacadeFiles
              # syncRuntimeFiles

        let allFiles =
                staticFiles
              # registerFiles
              # typesInitFiles
              # typeFiles
              # statementFiles

        in  Prelude.List.map Lude.File.Type Lude.File.Type withHeader allFiles
          : Output

-- Per-element keep/drop decision plus its warning, computed once from a
-- single QueryGen.run call and reused for both the Skip filter and the
-- warning list. Custom types use a pair of plain functions instead of an
-- equivalent record (see `typeSucceeds`/`typeWarning` below) purely because
-- that was the faster shape empirically for the type side, and the query
-- side re-uses `queryChecks` because calling QueryGen.run queryConfig lookup query from
-- more than one place in this function (once to decide keep/drop, again to
-- render, again for a warning -- each a fresh, separate call site in the
-- source) measurably multiplies Dhall's normalization cost per extra call
-- site, confirmed by bisection against `pgn generate` wall time (a few
-- seconds regressed to minutes with three call sites; this file keeps it to
-- two: one to build `queryChecks`, one for the final render).
let QueryCheck = { query : Model.Query, keep : Bool, warning : Optional Report }

let CombinedInputs =
      { queries : List QueryGen.Output
      , customTypes : List CustomTypeGen.Output
      , registrationTypes : List CustomTypeGen.Output
      }

let run =
      \(config : Config) ->
      \(input : Input) ->
        -- config's fields are independently Optional (a project may omit the
        -- whole config: block or any subset of its keys); the fallbacks are
        -- resolved here rather than in a separate config type or resolve
        -- step, since this is the root interpreter and Config above is
        -- exactly the generator's public Config.
        let packageName =
              Prelude.Optional.fold
                Text
                config.packageName
                Text
                (\(t : Text) -> t)
                input.name.inKebabCase

        let emitSync =
              Prelude.Optional.fold
                Bool
                config.emitSync
                Bool
                (\(b : Bool) -> b)
                False

        let onUnsupported =
              Prelude.Optional.fold
                OnUnsupported.Mode
                config.onUnsupported
                OnUnsupported.Mode
                (\(m : OnUnsupported.Mode) -> m)
                OnUnsupported.Mode.Fail

        let queryNameMappings =
              Prelude.Optional.fold
                (List PythonNameMapping.Query)
                config.queryNameMappings
                (List PythonNameMapping.Query)
                (\(mappings : List PythonNameMapping.Query) -> mappings)
                ([] : List PythonNameMapping.Query)

        let customTypeNameMappings =
              Prelude.Optional.fold
                (List PythonNameMapping.CustomType)
                config.customTypeNameMappings
                (List PythonNameMapping.CustomType)
                (\(mappings : List PythonNameMapping.CustomType) -> mappings)
                ([] : List PythonNameMapping.CustomType)

        let importName = Prelude.Text.replace "-" "_" packageName

        let resolvedConfig
            : ResolvedConfig
            = { packageName
              , importName
              , emitSync
              , onUnsupported
              , queryNameMappings
              , customTypeNameMappings
              }

        let queryConfig =
              resolvedConfig.{ emitSync, queryNameMappings }

        let customTypeConfig =
              resolvedConfig.{ customTypeNameMappings }

        let skip = merge { Fail = False, Skip = True } resolvedConfig.onUnsupported

        let typeSucceedsWith =
              \(candidateLookup : CustomKind.Lookup) ->
              \(ct : Model.CustomType) ->
                merge
                  { Ok =
                      \(_ : { value : CustomTypeGen.Output, warnings : List Report }) ->
                        True
                  , Err = \(_ : Report) -> False
                  }
                  (CustomTypeGen.run customTypeConfig candidateLookup ct)

        -- Nested under the type's own name so the warning names the type
        -- that failed, not just the inner member/column that triggered it
        -- (CustomType.run itself does not).
        let typeWarningWith =
              \(candidateLookup : CustomKind.Lookup) ->
              \(ct : Model.CustomType) ->
                merge
                  { Ok =
                      \(_ : { value : CustomTypeGen.Output, warnings : List Report }) ->
                        None Report
                  , Err =
                      \(err : Report) -> Some { path = [ ct.name.inSnakeCase ] # err.path, message = err.message }
                  }
                  (CustomTypeGen.run customTypeConfig candidateLookup ct)

        let resolvedCustomTypes =
              resolveCustomTypes
                resolvedConfig.customTypeNameMappings
                input.customTypes

        -- Nested custom support requires transitive closure: after one type is
        -- removed, composites depending on it must be reconsidered against the
        -- smaller lookup. Each bounded pass can only remove survivors.
        let effectiveResolvedCustomTypes
            : List ResolvedCustomType
            = if    skip
              then  Natural/fold
                      (Prelude.List.length Model.CustomType input.customTypes)
                      (List ResolvedCustomType)
                      ( \(survivors : List ResolvedCustomType) ->
                          let candidateLookup =
                                buildLookup (lookupEntries survivors)

                          in  Prelude.List.filter
                                ResolvedCustomType
                                ( \(customType : ResolvedCustomType) ->
                                    typeSucceedsWith
                                      candidateLookup
                                      customType.value
                                )
                                survivors
                      )
                      resolvedCustomTypes
              else  resolvedCustomTypes

        let effectiveCustomTypes =
              Prelude.List.map
                ResolvedCustomType
                Model.CustomType
                (\(customType : ResolvedCustomType) -> customType.value)
                effectiveResolvedCustomTypes

        let lookup =
              buildLookup (lookupEntries effectiveResolvedCustomTypes)

        -- Fail mode: identical to the pre-Skip code (traverseList straight
        -- over input.customTypes), so its error message/path is unchanged.
        let typesForCombine
            : Lude.Compiled.Type (List CustomTypeGen.Output)
            = Lude.Compiled.traverseList
                Model.CustomType
                CustomTypeGen.Output
                ( \(ct : Model.CustomType) ->
                    CustomTypeGen.run customTypeConfig lookup ct
                )
                effectiveCustomTypes

        let queryChecks
            : List QueryCheck
            = Prelude.List.map
                Model.Query
                QueryCheck
                ( \(query : Model.Query) ->
                    merge
                      { Ok =
                          \(_ : { value : QueryGen.Output, warnings : List Report }) ->
                            { query, keep = True, warning = None Report }
                      , Err = \(err : Report) -> { query, keep = False, warning = Some err }
                      }
                      (QueryGen.run queryConfig lookup query)
                )
                input.queries

        let effectiveQueries
            : List Model.Query
            = if    skip
              then  Prelude.List.map
                      QueryCheck
                      Model.Query
                      (\(qc : QueryCheck) -> qc.query)
                      (Prelude.List.filter QueryCheck (\(qc : QueryCheck) -> qc.keep) queryChecks)
              else  input.queries

        -- Fail mode: identical to the pre-Skip code (traverseList straight
        -- over input.queries), so its error message/path is unchanged.
        let queriesForCombine
            : Lude.Compiled.Type (List QueryGen.Output)
            = Lude.Compiled.traverseList
                Model.Query
                QueryGen.Output
                ( \(query : Model.Query) ->
                    QueryGen.run queryConfig lookup query
                )
                effectiveQueries

        let registrationTypesForCombine
            : Lude.Compiled.Type (List CustomTypeGen.Output)
            = Lude.Compiled.flatMap
                (List CustomTypeGen.Output)
                (List CustomTypeGen.Output)
                registrationOrder
                typesForCombine

        let skipWarnings
            : List Report
            = if    skip
              then    Prelude.List.unpackOptionals
                        Report
                        ( Prelude.List.map
                            Model.CustomType
                            (Optional Report)
                            (typeWarningWith lookup)
                            input.customTypes
                        )
                    # Prelude.List.unpackOptionals
                        Report
                        (Prelude.List.map QueryCheck (Optional Report) (\(qc : QueryCheck) -> qc.warning) queryChecks)
              else  [] : List Report

        let compiledInputs
            : Lude.Compiled.Type CombinedInputs
            = Lude.Compiled.map3
                (List QueryGen.Output)
                (List CustomTypeGen.Output)
                (List CustomTypeGen.Output)
                CombinedInputs
                ( \(queries : List QueryGen.Output) ->
                  \(customTypes : List CustomTypeGen.Output) ->
                  \(registrationTypes : List CustomTypeGen.Output) ->
                    { queries, customTypes, registrationTypes }
                )
                queriesForCombine
                typesForCombine
                registrationTypesForCombine

        let combined
            : Lude.Compiled.Type Output
            = Lude.Compiled.flatMap
                CombinedInputs
                Output
                ( \(compiled : CombinedInputs) ->
                    Lude.Compiled.map
                      {}
                      Output
                      ( \(_ : {}) ->
                          combineOutputs
                            resolvedConfig
                            input
                            compiled.queries
                            compiled.customTypes
                            compiled.registrationTypes
                      )
                      ( validateProjectNamespaces
                          resolvedConfig
                          compiled.queries
                          compiled.customTypes
                      )
                )
                compiledInputs

        let mappingsValid =
              Lude.Compiled.flatMap
                {}
                {}
                ( \(_ : {}) ->
                    Lude.Compiled.flatMap
                      {}
                      {}
                      ( \(_ : {}) ->
                          validateCustomTypeMappings
                            resolvedConfig.customTypeNameMappings
                            input.customTypes
                      )
                      ( validateQueryMappings
                          resolvedConfig.queryNameMappings
                          input.queries
                      )
                )
                (validateCustomTypeIdentities input.customTypes)

        let mappingsAndLocalsValid =
              Lude.Compiled.flatMap
                {}
                {}
                ( \(_ : {}) ->
                    validateLocalNamespaces
                      effectiveQueries
                      effectiveCustomTypes
                )
                mappingsValid

        in  Lude.Compiled.flatMap
              {}
              Output
              ( \(_ : {}) ->
                  Lude.Compiled.appendWarnings Output skipWarnings combined
              )
              mappingsAndLocalsValid

in  Sdk.Sigs.interpreter Config Input Output run
