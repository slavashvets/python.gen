let Sdk = ../Deps/Sdk.dhall

-- The fixed async runtime is emitted once per generated package.
let content =
      ''
      from __future__ import annotations

      from typing import LiteralString, TypeVar

      from psycopg import AsyncConnection
      from psycopg.rows import BaseRowFactory

      from ._core import NoRowError

      _T = TypeVar("_T")
      _Params = dict[str, object]


      async def fetch_optional(
          conn: AsyncConnection[object],
          sql: LiteralString,
          params: _Params,
          row_factory: BaseRowFactory[_T],
      ) -> _T | None:
          async with conn.cursor(row_factory=row_factory) as cur:
              _ = await cur.execute(sql, params)
              return await cur.fetchone()


      async def fetch_single(
          conn: AsyncConnection[object],
          sql: LiteralString,
          params: _Params,
          row_factory: BaseRowFactory[_T],
      ) -> _T:
          async with conn.cursor(row_factory=row_factory) as cur:
              _ = await cur.execute(sql, params)
              row = await cur.fetchone()
          if row is None:
              raise NoRowError(sql)
          return row


      async def fetch_many(
          conn: AsyncConnection[object],
          sql: LiteralString,
          params: _Params,
          row_factory: BaseRowFactory[_T],
      ) -> list[_T]:
          async with conn.cursor(row_factory=row_factory) as cur:
              _ = await cur.execute(sql, params)
              return await cur.fetchall()


      async def execute_rows_affected(
          conn: AsyncConnection[object],
          sql: LiteralString,
          params: _Params,
      ) -> int:
          async with conn.cursor() as cur:
              _ = await cur.execute(sql, params)
              return cur.rowcount


      async def execute_void(
          conn: AsyncConnection[object],
          sql: LiteralString,
          params: _Params,
      ) -> None:
          async with conn.cursor() as cur:
              _ = await cur.execute(sql, params)
      ''

-- The sync runtime mirrors the async helpers.
let syncContent =
      ''
      from __future__ import annotations

      from typing import LiteralString, TypeVar

      from psycopg import Connection
      from psycopg.rows import BaseRowFactory

      from .._core import NoRowError

      _T = TypeVar("_T")
      _Params = dict[str, object]


      def fetch_optional(
          conn: Connection[object],
          sql: LiteralString,
          params: _Params,
          row_factory: BaseRowFactory[_T],
      ) -> _T | None:
          with conn.cursor(row_factory=row_factory) as cur:
              _ = cur.execute(sql, params)
              return cur.fetchone()


      def fetch_single(
          conn: Connection[object],
          sql: LiteralString,
          params: _Params,
          row_factory: BaseRowFactory[_T],
      ) -> _T:
          with conn.cursor(row_factory=row_factory) as cur:
              _ = cur.execute(sql, params)
              row = cur.fetchone()
          if row is None:
              raise NoRowError(sql)
          return row


      def fetch_many(
          conn: Connection[object],
          sql: LiteralString,
          params: _Params,
          row_factory: BaseRowFactory[_T],
      ) -> list[_T]:
          with conn.cursor(row_factory=row_factory) as cur:
              _ = cur.execute(sql, params)
              return cur.fetchall()


      def execute_rows_affected(
          conn: Connection[object],
          sql: LiteralString,
          params: _Params,
      ) -> int:
          with conn.cursor() as cur:
              _ = cur.execute(sql, params)
              return cur.rowcount


      def execute_void(
          conn: Connection[object],
          sql: LiteralString,
          params: _Params,
      ) -> None:
          with conn.cursor() as cur:
              _ = cur.execute(sql, params)
      ''

in    Sdk.Sigs.template {} (\(_ : {}) -> content)
    /\ { runSync = \(_ : {}) -> syncContent }
