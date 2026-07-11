let Prelude = ../Deps/Prelude.dhall

let Lude = ../Deps/Lude.dhall

let Model = ../Deps/Contract.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let ResultColumns = ./ResultColumns.dhall

let Compiled = Lude.Compiled

let Config =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
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
      \(lookup : CustomKind.Lookup) ->
      \(rowClassName : Text) ->
      \(rows : Model.ResultRows) ->
        let shape = cardinalityShape rows.cardinality rowClassName

        let columns =
              Prelude.NonEmpty.toList Model.Member rows.columns

        in  Compiled.map
              ResultColumns.Output
              Output
              ( \(cols : ResultColumns.Output) ->
                  { returnType = shape.returnType
                  , helperName = shape.helperName
                  , rowClass = Some
                    { name = rowClassName
                    , fieldsBlock = cols.fieldsBlock
                    , decodeBlock = cols.decodeBlock
                    }
                  , imports = cols.imports
                  , callsDecode = True
                  }
              )
              (ResultColumns.run config lookup rowClassName columns)

let run =
      \(config : Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(rowClassName : Text) ->
      \(input : Input) ->
        merge
          { Void = Compiled.ok Output (noResult "None" "execute_void")
          , RowsAffected =
              Compiled.ok Output (noResult "int" "execute_rows_affected")
          , Rows = rowsOutput config lookup rowClassName
          }
          input

in  { Input, Output, RowClass, run }
