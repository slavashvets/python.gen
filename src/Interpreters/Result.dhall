let Prelude = ../Deps/Prelude.dhall

let Lude = ../Deps/Lude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let ResultColumns = ./ResultColumns.dhall

let Compiled = Lude.Compiled

-- rowClassName is supplied by the caller (Query.dhall derives it from the
-- query's own name) rather than living on Model.Result, so it rides on this
-- interpreter's own local Config instead of widening Input away from
-- Model.Result. ResultColumns below does not need it, so it is projected
-- back down to the narrower shared shape at that call site.
let Config =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
      , rowClassName : Text
      }

let Input = Model.Result

let RowClass = { name : Text, fieldsBlock : Text, decodeBlock : Text }

let Output =
      { returnType : Text
      , helperName : Text
      , rowClass : Optional RowClass
      , imports : ImportSet.Type
      , callsDecode : Bool
      }

let noResult
    : Text -> Text -> Output
    = \(returnType : Text) ->
      \(helperName : Text) ->
        { returnType
        , helperName
        , rowClass = None RowClass
        , imports = ImportSet.empty
        , callsDecode = False
        }

let cardinalityShape
    : Model.ResultRowsCardinality -> Text -> { returnType : Text, helperName : Text }
    = \(cardinality : Model.ResultRowsCardinality) ->
      \(rowClassName : Text) ->
        merge
          { Optional =
              { returnType = rowClassName ++ " | None"
              , helperName = "fetch_optional"
              }
          , Single = { returnType = rowClassName, helperName = "fetch_single" }
          , Multiple =
              { returnType = "list[" ++ rowClassName ++ "]"
              , helperName = "fetch_many"
              }
          }
          cardinality

let rowsOutput =
      \(config : Config) ->
      \(rows : Model.ResultRows) ->
        let shape = cardinalityShape rows.cardinality config.rowClassName

        let columns =
              Prelude.NonEmpty.toList Model.Member rows.columns

        in  Compiled.map
              ResultColumns.Output
              Output
              ( \(cols : ResultColumns.Output) ->
                  { returnType = shape.returnType
                  , helperName = shape.helperName
                  , rowClass = Some
                    { name = config.rowClassName
                    , fieldsBlock = cols.fieldsBlock
                    , decodeBlock = cols.decodeBlock
                    }
                  , imports = cols.imports
                  , callsDecode = True
                  }
              )
              ( ResultColumns.run
                  config.{ packageName, importName, emitSync, onUnsupported }
                  columns
              )

let run =
      \(config : Config) ->
      \(input : Input) ->
        merge
          { Void = Compiled.ok Output (noResult "None" "execute_void")
          , RowsAffected =
              Compiled.ok Output (noResult "int" "execute_rows_affected")
          , Rows = rowsOutput config
          }
          input

in  Sdk.Sigs.interpreter Config Input Output run /\ { RowClass }
