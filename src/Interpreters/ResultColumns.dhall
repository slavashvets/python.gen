let Prelude = ../Deps/Prelude.dhall

let Lude = ../Deps/Lude.dhall

let Model = ../Deps/Contract.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let Member = ./Member.dhall

let Compiled = Lude.Compiled

let Config = {}

let Input = List Model.Member

let Output = { fieldsBlock : Text, imports : ImportSet.Type }

let renderField
    : Member.Output -> Text
    = \(col : Member.Output) -> col.fieldName ++ ": " ++ col.pyType

let assemble
    : List Member.Output -> Output
    = \(columns : List Member.Output) ->
        -- args_row is positional, so Row field order must match pgn columns.
        { fieldsBlock =
            Prelude.Text.concatMapSep "\n" Member.Output renderField columns
        , imports =
            ImportSet.combineAll
              ( Prelude.List.map
                  Member.Output
                  ImportSet.Type
                  (\(col : Member.Output) -> col.imports)
                  columns
              )
        }

let run =
      \(_ : Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(input : Input) ->
        Compiled.map
          (List Member.Output)
          Output
          assemble
          ( Compiled.traverseList
              Model.Member
              Member.Output
              ( \(member : Model.Member) ->
                  Compiled.nest
                    Member.Output
                    member.pgName
                    (Member.runWithPrefix "_db_types." {=} lookup member)
              )
              input
          )

in  { Input, Output, run }
