let Sdk = ../Deps/Sdk.dhall

-- The surface-agnostic core of a generated package, emitted once at
-- _generated/_core.py. It owns the names shared by every module and by both the
-- async and sync surfaces: the JsonValue alias, the NoRowError/DecodeError
-- exceptions, and the require_array decode guard. It performs no I/O, so there is
-- exactly one copy regardless of surface. The two _runtime.py modules re-export
-- JsonValue/NoRowError/require_array from here so off-contract imports keep
-- working, and _rows.py, the statement modules, and the facades import these
-- names from _core directly.
let content =
      ''
      """Shared types and decode helpers, surface-agnostic; no I/O."""

      from __future__ import annotations

      from typing import cast

      type JsonValue = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]


      class NoRowError(RuntimeError):
          """A single-row query returned no rows."""


      class DecodeError(RuntimeError):
          """A row value failed to decode into its target type."""


      def require_array(value: object) -> list[object]:
          """Guard an enum-array column decode.

          psycopg returns an enum array as a Python list only when the enum type is
          registered on the connection (register_types); without it the value comes
          back as the raw array text, which would iterate into bogus members. Fail
          clearly instead.
          """
          if isinstance(value, list):
              return cast(list[object], value)
          raise RuntimeError(
              "enum array decoded as text; call register_types() on the connection "
              "before decoding enum-array columns"
          )
      ''

in  Sdk.Sigs.template {} (\(_ : {}) -> content)
