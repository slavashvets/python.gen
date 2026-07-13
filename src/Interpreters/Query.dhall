let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let PyIdent = ../Structures/PyIdent.dhall

let Surface = ../Structures/Surface.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let ResultModule = ./Result.dhall

let QueryFragmentsModule = ./QueryFragments.dhall

let ParamsMember = ./ParamsMember.dhall

let StatementModule = ../Templates/StatementModule.dhall

let Config =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
      }

let Compiled = Lude.Compiled

let Input = Model.Query

-- A query renders to one statement module: its own Row dataclass and decode
-- function (when it returns rows), the async function, and optional adjacent
-- sync function. rowClassName is still surfaced here (not just
-- internal to the rendered content) because Project.dhall's facade needs the
-- name to build the re-export line; the Row's full definition does not
-- leave this module.
let Output =
      { functionName : Text
      , rowClassName : Optional Text
      , modulePath : Text
      , content : Text
      }

let render =
      \(config : Config) ->
      \(input : Input) ->
      \(result : ResultModule.Output) ->
      \(fragments : QueryFragmentsModule.Output) ->
      \(params : List ParamsMember.Output) ->
        -- The function name is also the module filename and facade import name, so
        -- protect both Python syntax and the private globals in a statement module.
        -- SQL/dict/row lookups still key off raw names.
        let functionName = PyIdent.querySafeName input.name.inSnakeCase

        let paramSigLines =
              Prelude.List.map
                ParamsMember.Output
                Text
                (\(p : ParamsMember.Output) -> p.fieldName ++ ": " ++ p.pyType)
                params

        let paramDictEntries =
              Prelude.List.map
                ParamsMember.Output
                Text
                ( \(p : ParamsMember.Output) ->
                    "\"" ++ p.pgName ++ "\": " ++ p.bindExpr
                )
                params

        let paramImports =
              ImportSet.combineAll
                ( Prelude.List.map
                    ParamsMember.Output
                    ImportSet.Type
                    (\(p : ParamsMember.Output) -> p.imports)
                    params
                )

        let rowClassName =
              Prelude.Optional.map
                ResultModule.RowClass
                Text
                (\(rc : ResultModule.RowClass) -> rc.name)
                result.rowClass

        let rowDef =
              Prelude.Optional.map
                ResultModule.RowClass
                StatementModule.RowDef
                ( \(rc : ResultModule.RowClass) ->
                    { className = rc.name
                    , fieldsBlock = rc.fieldsBlock
                    }
                )
                result.rowClass

        -- The Row's own imports (JsonValue, Decimal, custom types, ...) and
        -- the parameters' imports both land in this one file now, so they
        -- merge into a single ImportSet instead of flowing to two separate
        -- consumers (the statement module and, formerly, _rows.py).
        let mergedImports = ImportSet.combine paramImports result.imports

        let content =
              StatementModule.run
                { functionName
                , returnType = result.returnType
                , helperName = result.helperName
                , sqlLiteral = fragments.sqlLiteral
                , rowDef
                , paramSigLines
                , paramDictEntries
                , imports = mergedImports
                , emitSync = config.emitSync
                , asyncSurface = Surface.async
                , syncSurface = Surface.sync
                }

        in  { functionName
            , rowClassName
            , modulePath = "statements/${functionName}.py"
            , content
            }

let run =
      \(config : Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(input : Input) ->
        let rowClassName = input.name.inPascalCase ++ "Row"

        in  Compiled.nest
              Output
              input.srcPath
              ( Compiled.map3
                  ResultModule.Output
                  QueryFragmentsModule.Output
                  (List ParamsMember.Output)
                  Output
                  (render config input)
                  ( Compiled.nest
                      ResultModule.Output
                      "result"
                      ( ResultModule.run
                          (config /\ { rowClassName })
                          lookup
                          input.result
                      )
                  )
                  ( Compiled.nest
                      QueryFragmentsModule.Output
                      "sql"
                      (QueryFragmentsModule.run config input.fragments)
                  )
                  ( Compiled.nest
                      (List ParamsMember.Output)
                      "params"
                      ( Compiled.traverseList
                          Model.Member
                          ParamsMember.Output
                          ( \(member : Model.Member) ->
                              Compiled.nest
                                ParamsMember.Output
                                member.pgName
                                (ParamsMember.run config lookup member)
                          )
                          input.params
                      )
                  )
              )

in  { Input, Output, run }
