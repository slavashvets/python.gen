let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Binding =
      { namespace : Text
      , owner : Text
      , name : Text
      , remediation : Text
      }

let Collision =
      { namespace : Text
      , firstOwner : Text
      , secondOwner : Text
      , name : Text
      , remediation : Text
      }

let State = { seen : List Binding, collision : Optional Collision }

let validate =
      \(bindings : List Binding) ->
        let step =
              \(binding : Binding) ->
              \(state : State) ->
                Prelude.Optional.fold
                  Collision
                  state.collision
                  State
                  (\(_ : Collision) -> state)
                  ( let previousOwner =
                          List/fold
                            Binding
                            state.seen
                            (Optional Text)
                            ( \(previous : Binding) ->
                              \(found : Optional Text) ->
                                if    Text/equal
                                        previous.namespace
                                        binding.namespace
                                      && Text/equal previous.name binding.name
                                then  Some previous.owner
                                else  found
                            )
                            (None Text)

                    let collision =
                          Prelude.Optional.fold
                            Text
                            previousOwner
                            (Optional Collision)
                            ( \(owner : Text) ->
                                Some
                                  { namespace = binding.namespace
                                  , firstOwner = owner
                                  , secondOwner = binding.owner
                                  , name = binding.name
                                  , remediation = binding.remediation
                                  }
                            )
                            (None Collision)

                    in  { seen = state.seen # [ binding ], collision }
                  )

        let result =
              List/fold
                Binding
                bindings
                State
                step
                { seen = [] : List Binding, collision = None Collision }

        in  Prelude.Optional.fold
              Collision
              result.collision
              (Lude.Compiled.Type {})
              ( \(collision : Collision) ->
                  Lude.Compiled.report
                    {}
                    [ "pythonNames", collision.namespace, collision.name ]
                    (     "Generated Python name collision in "
                      ++  collision.namespace
                      ++  ": "
                      ++  collision.firstOwner
                      ++  " and "
                      ++  collision.secondOwner
                      ++  " both resolve to \""
                      ++  collision.name
                      ++  "\". "
                      ++  collision.remediation
                    )
              )
              (Lude.Compiled.ok {} {=})

in  { Binding, validate }
