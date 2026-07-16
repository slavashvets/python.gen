let Sdk = ../Deps/Sdk.dhall

-- The surface-agnostic core is emitted once per generated package.
let content =
      ''
      """Shared types and errors, surface-agnostic; no I/O."""

      from __future__ import annotations

      type JsonValue = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]


      class NoRowError(RuntimeError):
          """A single-row query returned no rows."""

          def __init__(self, sql: str) -> None:
              self.sql = sql
              super().__init__(f"single-row query returned no rows: {sql}")
      ''

in  Sdk.Sigs.template {} (\(_ : {}) -> content)
