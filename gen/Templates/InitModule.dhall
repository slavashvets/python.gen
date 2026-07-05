let Algebra = ../Algebras/Template.dhall

-- A minimal package __init__.py: a module docstring plus an empty __all__.
-- Used for the _generated subpackage root and the statements subpackage. The
-- flat public surface is the package-root facade (FacadeModule); the types
-- subpackage uses TypesInit. These two inits stay empty so the subpackages add
-- no names of their own.
let Params = { docstring : Text }

let render =
      \(params : Params) ->
        ''
        """${params.docstring}"""

        __all__: list[str] = []
        ''

in  Algebra.module Params render
