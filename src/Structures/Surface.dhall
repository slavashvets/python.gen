-- Render tokens for the two explicit functions co-located in each canonical
-- statement module. Both surfaces import the same core and custom types.
let Surface =
      { defKeyword : Text
      , connType : Text
      , awaitKw : Text
      , functionSuffix : Text
      , runtimePrefix : Text
      , helperSuffix : Text
      , corePrefix : Text
      }

let async
    : Surface
    = { defKeyword = "async def"
      , connType = "AsyncConnection"
      , awaitKw = "await "
      , functionSuffix = ""
      , runtimePrefix = ".._runtime"
      , helperSuffix = ""
      , corePrefix = ".._core"
      }

let sync
    : Surface
    = { defKeyword = "def"
      , connType = "Connection"
      , awaitKw = ""
      , functionSuffix = "_sync"
      , runtimePrefix = "..sync._runtime"
      , helperSuffix = "_sync"
      , corePrefix = ".._core"
      }

in  { Type = Surface, async, sync }
