let Deps = ../Deps/package.dhall

let Algebra = ../Algebras/Interpreter.dhall

let Prelude = Deps.Prelude

let Sdk = Deps.Sdk

let Lude = Deps.Lude

let Compiled = Lude.Compiled

let Model = Deps.Sdk.Project

let Input = Model.QueryFragments

let Output = { sqlLiteral : Text }

-- Escape a raw SQL fragment for a Python triple-quoted string literal. Newlines
-- stay literal (the literal is multiline); only sequences that would break the
-- literal or the placeholder protocol are escaped. Order is load-bearing:
-- backslash first (so later escapes are not re-escaped), then the closing quote
-- (so an accidental `"""` cannot form), then the psycopg placeholder sigil.
let escapeSql
    : Text -> Text
    = \(raw : Text) ->
        Prelude.Function.composeList
          Text
          [ Prelude.Text.replace "\\" "\\\\"
          , Prelude.Text.replace "\"" "\\\""
          , Prelude.Text.replace "%" "%%"
          ]
          raw

let renderFragment
    : Model.QueryFragment -> Text
    = \(fragment : Model.QueryFragment) ->
        merge
          { Sql = escapeSql
          , Var = \(var : Model.Var) -> "%(" ++ var.rawName ++ ")s"
          }
          fragment

let renderSql
    : Input -> Text
    = \(fragments : Input) ->
        Prelude.Text.concatMap Model.QueryFragment renderFragment fragments

let run =
      \(config : Algebra.Config) ->
      \(input : Input) ->
        Compiled.ok Output { sqlLiteral = renderSql input }

in  Algebra.module Input Output run
