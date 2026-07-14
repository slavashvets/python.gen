-- Applies this generator to gen-sdk's shared cross-backend fixture project
-- (the same "music_catalogue" project java.gen's own fixtures/Exhaustive.dhall
-- exercises), so a Python client compiles from it and passes basedpyright
-- strict. Loading through src/Deps/Sdk.dhall keeps this fixture on the same
-- ordinary sha256-pinned gen-sdk import as the generator.
--
-- The fixture project deliberately covers PG types this generator does not
-- support (box, inet, money, ranges, ...), so onUnsupported is set to Skip:
-- those statements/types are dropped with a warning instead of aborting the
-- whole compile.
--
-- CI evaluates this fixture with the pinned fork-aware directory-tree action.
-- Standard `dhall to-directory-tree` cannot evaluate the pgn fork's Text/equal
-- builtin used by the generator.
let Sdk = ../src/Deps/Sdk.dhall

let Gen = ../src/package.dhall

let OnUnsupported = ../src/Structures/OnUnsupported.dhall

let project = Sdk.Fixtures.Exhaustive

let config =
      Some
        { packageName = None Text
        , emitSync = Some False
        , onUnsupported = Some OnUnsupported.Mode.Skip
        }

in  Sdk.Output.toFileMap (Gen.compile config project)
