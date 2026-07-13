let Prelude = ../Deps/Prelude.dhall

let PythonName = { snakeCase : Text, pascalCase : Text }

let Query = { source : Text, target : PythonName }

let CustomTypeSource = { schema : Text, name : Text }

let CustomType = { source : CustomTypeSource, target : PythonName }

let resolveQuery =
      \(mappings : List Query) ->
      \(source : Text) ->
      \(defaultName : PythonName) ->
        List/fold
          Query
          mappings
          PythonName
          ( \(mapping : Query) ->
            \(resolved : PythonName) ->
              if Text/equal mapping.source source then mapping.target else resolved
          )
          defaultName

let resolveCustomType =
      \(mappings : List CustomType) ->
      \(source : CustomTypeSource) ->
      \(defaultName : PythonName) ->
        List/fold
          CustomType
          mappings
          PythonName
          ( \(mapping : CustomType) ->
            \(resolved : PythonName) ->
              if    Text/equal mapping.source.schema source.schema
                    && Text/equal mapping.source.name source.name
              then  mapping.target
              else  resolved
          )
          defaultName

in  { PythonName
    , Query
    , CustomTypeSource
    , CustomType
    , resolveQuery
    , resolveCustomType
    }
