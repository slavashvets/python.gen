-- Applies this generator to gen-sdk's shared cross-backend fixture project
-- (the same "music_catalogue" project java.gen's own demos/Exhaustive.dhall
-- exercises), so a Python client compiles from it and passes basedpyright
-- strict. Pinned directly at gen-sdk's package.dhall, separately from
-- src/Deps/Sdk.dhall: that file only imports gen-sdk's `package.dhall` `as
-- Source` for RAM, and this fixture load doesn't need that mode.
--
-- The fixture project deliberately covers PG types this generator does not
-- support (box, inet, money, ranges, ...), so onUnsupported is set to Skip:
-- those statements/types are dropped with a warning instead of aborting the
-- whole compile.
--
-- Intended to be executed with:
--
-- ```bash
-- dhall to-directory-tree --file demos/Exhaustive.dhall --output <dir> --allow-path-separators
-- ```
let Sdk = ../src/Deps/Sdk.dhall

let Gen = ../src/package.dhall

let OnUnsupported = ../src/Structures/OnUnsupported.dhall

let project = Sdk.Fixtures.Exhaustive

let config =
      Some
        { packageName = None Text
        , sync = Some False
        , onUnsupported = Some OnUnsupported.Mode.Skip
        }

in  Sdk.Output.toFileMap (Gen.compile config project)
