let Prelude = ../Deps/Prelude.dhall

-- A custom-type import line: "from ..types.<moduleName> import <className>".
-- dedupKey identifies the type for deduplication and orders the rendered import
-- block. Dhall (upstream) has no Text comparison, so the caller assigns each
-- distinct custom type its alphabetical position in project.customTypes as the
-- key; dedup keys on it and the render step sorts ascending to stay alphabetical.
let CustomImport = { className : Text, moduleName : Text, dedupKey : Natural }

let Self =
      { uuid : Bool
      , datetime : Bool
      , date : Bool
      , time : Bool
      , timedelta : Bool
      , decimal : Bool
      , jsonb : Bool
      , json : Bool
      , jsonValue : Bool
      , enumArray : Bool
      , customTypes : List CustomImport
      }

let base =
      { uuid = False
      , datetime = False
      , date = False
      , time = False
      , timedelta = False
      , decimal = False
      , jsonb = False
      , json = False
      , jsonValue = False
      , enumArray = False
      , customTypes = [] : List CustomImport
      }

let empty
    : Self
    = base

let uuid
    : Self
    = base // { uuid = True }

let datetime
    : Self
    = base // { datetime = True }

let date
    : Self
    = base // { date = True }

let time
    : Self
    = base // { time = True }

let timedelta
    : Self
    = base // { timedelta = True }

let decimal
    : Self
    = base // { decimal = True }

let jsonb
    : Self
    = base // { jsonb = True }

let json
    : Self
    = base // { json = True }

let jsonValue
    : Self
    = base // { jsonValue = True }

let enumArray
    : Self
    = base // { enumArray = True }

let custom
    : CustomImport -> Self
    = \(c : CustomImport) -> base // { customTypes = [ c ] }

-- Named-type imports dedup and sort on `order`, the type's alphabetical index in
-- project.customTypes. Two references to the same type carry the same order and
-- collapse; distinct types keep distinct keys so the render step can sort them.
let customEnum
    : { className : Text, moduleName : Text, order : Natural } -> Self
    = \(c : { className : Text, moduleName : Text, order : Natural }) ->
        custom
          { className = c.className, moduleName = c.moduleName, dedupKey = c.order }

let customComposite
    : { className : Text, moduleName : Text, order : Natural } -> Self
    = \(c : { className : Text, moduleName : Text, order : Natural }) ->
        custom
          { className = c.className, moduleName = c.moduleName, dedupKey = c.order }

let eqNat =
      \(a : Natural) ->
      \(b : Natural) ->
        Natural/isZero (Natural/subtract a b)
        && Natural/isZero (Natural/subtract b a)

let dedupCustoms
    : List CustomImport -> List CustomImport
    = \(items : List CustomImport) ->
        let State = { seen : List Natural, acc : List CustomImport }

        let step =
              \(item : CustomImport) ->
              \(state : State) ->
                let known =
                      Prelude.List.any
                        Natural
                        (\(k : Natural) -> eqNat k item.dedupKey)
                        state.seen

                in  if    known
                    then  state
                    else  { seen = state.seen # [ item.dedupKey ]
                          , acc = state.acc # [ item ]
                          }

        in  ( List/fold
                CustomImport
                items
                State
                step
                { seen = [] : List Natural, acc = [] : List CustomImport }
            ).acc

let leNat = \(a : Natural) -> \(b : Natural) -> Natural/isZero (Natural/subtract b a)

-- Insertion sort over custom imports by ascending dedupKey (the alphabetical
-- order). The list is tiny (one or two types per module), so the cost is moot
-- and the result is a stable alphabetical import block.
let sortCustoms
    : List CustomImport -> List CustomImport
    = \(items : List CustomImport) ->
        let insert =
              \(item : CustomImport) ->
              \(acc : List CustomImport) ->
                let State = { placed : Bool, out : List CustomImport }

                -- foldLeft so the scan runs left-to-right and `item` lands before
                -- the FIRST element that is >= it (a right List/fold visits the
                -- list back-to-front and would insert before the last such
                -- element, mis-ordering blocks of 3+ types).
                let step =
                      \(state : State) ->
                      \(cur : CustomImport) ->
                        if    state.placed
                        then  { placed = True, out = state.out # [ cur ] }
                        else  if leNat item.dedupKey cur.dedupKey
                        then  { placed = True
                              , out = state.out # [ item, cur ]
                              }
                        else  { placed = False, out = state.out # [ cur ] }

                let folded =
                      Prelude.List.foldLeft
                        CustomImport
                        acc
                        State
                        step
                        { placed = False, out = [] : List CustomImport }

                in  if    folded.placed
                    then  folded.out
                    else  folded.out # [ item ]

        in  List/fold CustomImport items (List CustomImport) insert ([] : List CustomImport)

let combine =
      \(left : Self) ->
      \(right : Self) ->
        { uuid = left.uuid || right.uuid
        , datetime = left.datetime || right.datetime
        , date = left.date || right.date
        , time = left.time || right.time
        , timedelta = left.timedelta || right.timedelta
        , decimal = left.decimal || right.decimal
        , jsonb = left.jsonb || right.jsonb
        , json = left.json || right.json
        , jsonValue = left.jsonValue || right.jsonValue
        , enumArray = left.enumArray || right.enumArray
        , customTypes = dedupCustoms (left.customTypes # right.customTypes)
        }

let combineAll
    : List Self -> Self
    = \(sets : List Self) -> List/fold Self sets Self combine empty

let sortedCustoms
    : Self -> List CustomImport
    = \(self : Self) -> sortCustoms self.customTypes

in  { Type = Self
    , CustomImport
    , empty
    , uuid
    , datetime
    , date
    , time
    , timedelta
    , decimal
    , jsonb
    , json
    , jsonValue
    , enumArray
    , custom
    , customEnum
    , customComposite
    , combine
    , combineAll
    , sortedCustoms
    }
