let Deps = ../Deps/package.dhall

let Algebra = ../Algebras/Interpreter.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let Member = ./Member.dhall

let Prelude = Deps.Prelude

let Lude = Deps.Lude

let Compiled = Lude.Compiled

let Model = Deps.Project

let Input = List Model.Member

let Output = { fieldsBlock : Text, decodeBlock : Text, imports : ImportSet.Type }

let renderField
    : Member.Output -> Text
    = \(col : Member.Output) -> col.fieldName ++ ": " ++ col.pyType

let renderDecodeKwarg
    : Member.Output -> Text
    = \(col : Member.Output) ->
        let src = "row[\"" ++ col.pgName ++ "\"]"

        in  col.fieldName ++ "=" ++ col.decodeExpr src ++ ","

let assemble
    : List Member.Output -> Output
    = \(columns : List Member.Output) ->
        { fieldsBlock =
            Prelude.Text.concatMapSep "\n" Member.Output renderField columns
        , decodeBlock =
            Prelude.Text.concatMapSep
              "\n"
              Member.Output
              renderDecodeKwarg
              columns
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
      \(config : Algebra.Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(rowClassName : Text) ->
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
                    (Member.run config lookup member)
              )
              input
          )

in  { Input, Output, run }
