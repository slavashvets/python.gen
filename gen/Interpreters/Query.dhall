let Deps = ../Deps/package.dhall

let Algebra = ../Algebras/Interpreter.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let PyIdent = ../Structures/PyIdent.dhall

let Surface = ../Structures/Surface.dhall

let RowsModule = ../Templates/RowsModule.dhall

let ResultModule = ./Result.dhall

let QueryFragmentsModule = ./QueryFragments.dhall

let ParamsMember = ./ParamsMember.dhall

let StatementModule = ../Templates/StatementModule.dhall

let Prelude = Deps.Prelude

let Lude = Deps.Lude

let Compiled = Lude.Compiled

let Model = Deps.Sdk.Project

let Input = Model.Query

-- A query contributes a shared Row (assembled into `_rows.py` by Project) plus a
-- thin statement module per surface. asyncModule is always emitted; syncModule is
-- emitted only when config.emitSync. rowImports are the result-column imports,
-- folded into `_rows.py`.
let Output =
      { functionName : Text
      , rowClassName : Optional Text
      , rowDef : Optional RowsModule.RowDef
      , rowImports : ImportSet.Type
      , asyncModulePath : Text
      , asyncContent : Text
      , syncModulePath : Text
      , syncContent : Text
      }

let render =
      \(config : Algebra.Config) ->
      \(input : Input) ->
      \(result : ResultModule.Output) ->
      \(fragments : QueryFragmentsModule.Output) ->
      \(params : List ParamsMember.Output) ->
        -- The function name is also the module filename and the facade import name;
        -- a query named like a Python keyword would emit `def class(...)`, a module
        -- `class.py`, and `from ... import class` (all SyntaxErrors), so sanitize it
        -- like params and result columns. SQL/dict/row lookups key off raw names.
        let functionName = PyIdent.pySafeName input.name.inSnakeCase

        let decodeName = "decode_${functionName}"

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
                RowsModule.RowDef
                ( \(rc : ResultModule.RowClass) ->
                    { className = rc.name
                    , fieldsBlock = rc.fieldsBlock
                    , decodeBlock = rc.decodeBlock
                    , decodeName
                    }
                )
                result.rowClass

        let mkModule =
              \(surface : Surface.Type) ->
                StatementModule.run
                  { functionName
                  , returnType = result.returnType
                  , helperName = result.helperName
                  , callsDecode = result.callsDecode
                  , sqlLiteral = fragments.sqlLiteral
                  , rowClassName
                  , decodeName
                  , paramSigLines
                  , paramDictEntries
                  , imports = paramImports
                  , surface
                  }

        in  { functionName
            , rowClassName
            , rowDef
            , rowImports = result.imports
            , asyncModulePath = "statements/${functionName}.py"
            , asyncContent = mkModule Surface.async
            , syncModulePath = "sync/statements/${functionName}.py"
            , syncContent = mkModule Surface.sync
            }

let run =
      \(config : Algebra.Config) ->
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
                      (ResultModule.run config lookup rowClassName input.result)
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
