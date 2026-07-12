let Sdk = ../Deps/Sdk.dhall

-- The fixed _runtime.py body, emitted once per generated package. No per-query
-- customization. Mirrors DESIGN section 3 with two strict-clean adjustments the
-- design's hard "basedpyright strict, zero warnings" constraint forces: the
-- unused Sequence import is dropped, and each cursor.execute result is bound to
-- `_` so reportUnusedCallResult stays quiet. This module is I/O-only: the shared
-- JsonValue/NoRowError/require_array names live in _core and are re-exported here
-- so off-contract `from .._runtime import ...` keeps working.
let content =
      ''
      from __future__ import annotations

      from collections.abc import Callable, Mapping
      from typing import TypeVar

      from psycopg import AsyncConnection
      from psycopg.rows import dict_row

      from ._core import JsonValue as JsonValue, NoRowError as NoRowError, require_array as require_array

      _T = TypeVar("_T")
      _Row = Mapping[str, object]
      _Params = Mapping[str, object]


      async def fetch_optional(
          conn: AsyncConnection[object],
          sql: bytes,
          params: _Params,
          decode: Callable[[_Row], _T],
      ) -> _T | None:
          async with conn.cursor(row_factory=dict_row) as cur:
              _ = await cur.execute(sql, params)
              row = await cur.fetchone()
          return None if row is None else decode(row)


      async def fetch_single(
          conn: AsyncConnection[object],
          sql: bytes,
          params: _Params,
          decode: Callable[[_Row], _T],
      ) -> _T:
          async with conn.cursor(row_factory=dict_row) as cur:
              _ = await cur.execute(sql, params)
              row = await cur.fetchone()
          if row is None:
              raise NoRowError(sql.decode())
          return decode(row)


      async def fetch_many(
          conn: AsyncConnection[object],
          sql: bytes,
          params: _Params,
          decode: Callable[[_Row], _T],
      ) -> list[_T]:
          async with conn.cursor(row_factory=dict_row) as cur:
              _ = await cur.execute(sql, params)
              rows = await cur.fetchall()
          return [decode(row) for row in rows]


      async def execute_rows_affected(
          conn: AsyncConnection[object],
          sql: bytes,
          params: _Params,
      ) -> int:
          async with conn.cursor() as cur:
              _ = await cur.execute(sql, params)
              return cur.rowcount


      async def execute_void(
          conn: AsyncConnection[object],
          sql: bytes,
          params: _Params,
      ) -> None:
          async with conn.cursor() as cur:
              _ = await cur.execute(sql, params)
      ''

-- The sync mirror, emitted at _generated/sync/_runtime.py when config.sync is True. The
-- five helpers are the same shape with `def`/`Connection`/`with`/no-`await`.
-- JsonValue/NoRowError/require_array are re-exported from _core (two levels up)
-- so both surfaces share one canonical identity rather than two equal-but-
-- distinct definitions.
let syncContent =
      ''
      from __future__ import annotations

      from collections.abc import Callable, Mapping
      from typing import TypeVar

      from psycopg import Connection
      from psycopg.rows import dict_row

      from .._core import JsonValue as JsonValue, NoRowError as NoRowError, require_array as require_array

      _T = TypeVar("_T")
      _Row = Mapping[str, object]
      _Params = Mapping[str, object]


      def fetch_optional(
          conn: Connection[object],
          sql: bytes,
          params: _Params,
          decode: Callable[[_Row], _T],
      ) -> _T | None:
          with conn.cursor(row_factory=dict_row) as cur:
              _ = cur.execute(sql, params)
              row = cur.fetchone()
          return None if row is None else decode(row)


      def fetch_single(
          conn: Connection[object],
          sql: bytes,
          params: _Params,
          decode: Callable[[_Row], _T],
      ) -> _T:
          with conn.cursor(row_factory=dict_row) as cur:
              _ = cur.execute(sql, params)
              row = cur.fetchone()
          if row is None:
              raise NoRowError(sql.decode())
          return decode(row)


      def fetch_many(
          conn: Connection[object],
          sql: bytes,
          params: _Params,
          decode: Callable[[_Row], _T],
      ) -> list[_T]:
          with conn.cursor(row_factory=dict_row) as cur:
              _ = cur.execute(sql, params)
              rows = cur.fetchall()
          return [decode(row) for row in rows]


      def execute_rows_affected(
          conn: Connection[object],
          sql: bytes,
          params: _Params,
      ) -> int:
          with conn.cursor() as cur:
              _ = cur.execute(sql, params)
              return cur.rowcount


      def execute_void(
          conn: Connection[object],
          sql: bytes,
          params: _Params,
      ) -> None:
          with conn.cursor() as cur:
              _ = cur.execute(sql, params)
      ''

in    Sdk.Sigs.template {} (\(_ : {}) -> content)
    /\ { runSync = \(_ : {}) -> syncContent }
