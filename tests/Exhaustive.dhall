-- Applies this generator to gen-sdk's shared cross-backend fixture project
-- (the same "music_catalogue" project java.gen's own tests/Exhaustive.dhall
-- exercises), so a Python client compiles from it and passes basedpyright
-- strict. Pinned directly at gen-sdk's package.dhall, separately from
-- gen/Deps/Sdk.dhall: that file only imports gen-sdk's `module.dhall` (the
-- generator-construction function), which has no `Fixtures` field.
--
-- The fixture project deliberately covers PG types this generator does not
-- support (box, inet, money, ranges, ...), so onUnsupported is set to Skip:
-- those statements/types are dropped with a warning instead of aborting the
-- whole compile.
--
-- Intended to be executed with:
--
-- ```bash
-- dhall to-directory-tree --file tests/Exhaustive.dhall --output <dir> --allow-path-separators
-- ```
let Sdk = ../gen/Deps/Sdk.dhall

let Gen = ../gen/Gen.dhall

let OnUnsupported = ../gen/Structures/OnUnsupported.dhall

let project = Sdk.Fixtures.Exhaustive

let config =
      Some
        { packageName = None Text
        , emitSync = Some True
        , onUnsupported = Some OnUnsupported.Mode.Skip
        }

in  Gen.compileToFileMap config project
