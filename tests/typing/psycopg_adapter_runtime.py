from __future__ import annotations

import keyword
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, fields, is_dataclass
from enum import StrEnum
from typing import Any, LiteralString

from psycopg import AsyncConnection, Connection
from psycopg.rows import BaseRowFactory, args_row
from psycopg.types.composite import CompositeInfo, register_composite
from psycopg.types.enum import EnumInfo, register_enum


class Mood(StrEnum):
    HAPPY = "happy"
    SAD = "sad"


@dataclass(frozen=True, slots=True)
class Leaf:
    class_: int
    pg_decode: str
    pg_encode: str | None


@dataclass(frozen=True, slots=True)
class Wrapper:
    leaf: Leaf
    mood: Mood
    note: str | None


@dataclass(frozen=True, slots=True)
class EnumRow:
    mood: Mood


@dataclass(frozen=True, slots=True)
class EnumArrayRow:
    moods: list[Mood | None]


@dataclass(frozen=True, slots=True)
class EnumGridRow:
    moods: list[list[Mood]]


@dataclass(frozen=True, slots=True)
class LeafRow:
    value: Leaf


@dataclass(frozen=True, slots=True)
class LeafArrayRow:
    values: list[Leaf]


@dataclass(frozen=True, slots=True)
class WrapperRow:
    value: Wrapper


@dataclass(frozen=True, slots=True)
class SanitizedRow:
    class_: str
    value: Leaf


type _ObjectMaker[T] = Callable[[Sequence[Any], CompositeInfo], T]
type _SequenceMaker[T] = Callable[[T, CompositeInfo], Sequence[Any]]


def _python_name(name: str) -> str:
    if name == "class":
        assert keyword.iskeyword(name)
        return "class_"
    return name


def dataclass_callbacks[T](cls: type[T]) -> tuple[_ObjectMaker[T], _SequenceMaker[T]]:
    if not is_dataclass(cls):
        raise TypeError(f"{cls.__name__} must be a dataclass")

    model_fields = fields(cls)
    model_names = tuple(field.name for field in model_fields)

    def make_object(values: Sequence[Any], info: CompositeInfo) -> T:
        names = tuple(_python_name(name) for name in info.field_names)
        assert names == model_names
        assert len(values) == len(model_fields)
        return cls(**dict(zip(names, values, strict=True)))

    def make_sequence(obj: T, info: CompositeInfo) -> Sequence[Any]:
        names = tuple(_python_name(name) for name in info.field_names)
        assert names == model_names
        return tuple(getattr(obj, field.name) for field in model_fields)

    return make_object, make_sequence


_leaf_make_object, _leaf_make_sequence = dataclass_callbacks(Leaf)
_wrapper_make_object, _wrapper_make_sequence = dataclass_callbacks(Wrapper)


async def register_adapter_types_async(conn: AsyncConnection[object]) -> None:
    mood_info = await EnumInfo.fetch(conn, "public.m_adapter_mood")
    assert mood_info is not None
    register_enum(
        mood_info,
        conn,
        Mood,
        mapping={member: member.value for member in Mood},
    )
    assert mood_info.enum is Mood

    # Register dependencies before the alphabetically earlier wrapper type.
    leaf_info = await CompositeInfo.fetch(conn, "public.z_adapter_leaf")
    assert leaf_info is not None
    register_composite(
        leaf_info,
        conn,
        Leaf,
        make_object=_leaf_make_object,
        make_sequence=_leaf_make_sequence,
    )
    assert leaf_info.python_type is Leaf

    wrapper_info = await CompositeInfo.fetch(conn, "public.a_adapter_wrapper")
    assert wrapper_info is not None
    register_composite(
        wrapper_info,
        conn,
        Wrapper,
        make_object=_wrapper_make_object,
        make_sequence=_wrapper_make_sequence,
    )
    assert wrapper_info.python_type is Wrapper


def register_adapter_types_sync(conn: Connection[object]) -> None:
    mood_info = EnumInfo.fetch(conn, "public.m_adapter_mood")
    assert mood_info is not None
    register_enum(
        mood_info,
        conn,
        Mood,
        mapping={member: member.value for member in Mood},
    )
    assert mood_info.enum is Mood

    leaf_info = CompositeInfo.fetch(conn, "public.z_adapter_leaf")
    assert leaf_info is not None
    register_composite(
        leaf_info,
        conn,
        Leaf,
        make_object=_leaf_make_object,
        make_sequence=_leaf_make_sequence,
    )
    assert leaf_info.python_type is Leaf

    wrapper_info = CompositeInfo.fetch(conn, "public.a_adapter_wrapper")
    assert wrapper_info is not None
    register_composite(
        wrapper_info,
        conn,
        Wrapper,
        make_object=_wrapper_make_object,
        make_sequence=_wrapper_make_sequence,
    )
    assert wrapper_info.python_type is Wrapper


async def fetch_one_async[T](
    conn: AsyncConnection[object],
    sql: LiteralString,
    params: Mapping[str, object],
    row_factory: BaseRowFactory[T],
) -> T:
    async with conn.cursor(row_factory=row_factory) as cursor:
        await cursor.execute(sql, params)
        row = await cursor.fetchone()
    if row is None:
        raise RuntimeError("query returned no row")
    return row


def fetch_one_sync[T](
    conn: Connection[object],
    sql: LiteralString,
    params: Mapping[str, object],
    row_factory: BaseRowFactory[T],
) -> T:
    with conn.cursor(row_factory=row_factory) as cursor:
        cursor.execute(sql, params)
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError("query returned no row")
    return row


async def prove_async_row_inference(conn: AsyncConnection[object]) -> None:
    enum_row: EnumRow = await fetch_one_async(conn, "SELECT NULL", {}, args_row(EnumRow))
    enum_array_row: EnumArrayRow = await fetch_one_async(conn, "SELECT NULL", {}, args_row(EnumArrayRow))
    enum_grid_row: EnumGridRow = await fetch_one_async(conn, "SELECT NULL", {}, args_row(EnumGridRow))
    leaf_row: LeafRow = await fetch_one_async(conn, "SELECT NULL", {}, args_row(LeafRow))
    leaf_array_row: LeafArrayRow = await fetch_one_async(conn, "SELECT NULL", {}, args_row(LeafArrayRow))
    wrapper_row: WrapperRow = await fetch_one_async(conn, "SELECT NULL", {}, args_row(WrapperRow))
    sanitized_row: SanitizedRow = await fetch_one_async(conn, "SELECT NULL, NULL", {}, args_row(SanitizedRow))
    _ = (
        enum_row,
        enum_array_row,
        enum_grid_row,
        leaf_row,
        leaf_array_row,
        wrapper_row,
        sanitized_row,
    )


def prove_sync_row_inference(conn: Connection[object]) -> None:
    enum_row: EnumRow = fetch_one_sync(conn, "SELECT NULL", {}, args_row(EnumRow))
    enum_array_row: EnumArrayRow = fetch_one_sync(conn, "SELECT NULL", {}, args_row(EnumArrayRow))
    enum_grid_row: EnumGridRow = fetch_one_sync(conn, "SELECT NULL", {}, args_row(EnumGridRow))
    leaf_row: LeafRow = fetch_one_sync(conn, "SELECT NULL", {}, args_row(LeafRow))
    leaf_array_row: LeafArrayRow = fetch_one_sync(conn, "SELECT NULL", {}, args_row(LeafArrayRow))
    wrapper_row: WrapperRow = fetch_one_sync(conn, "SELECT NULL", {}, args_row(WrapperRow))
    sanitized_row: SanitizedRow = fetch_one_sync(conn, "SELECT NULL, NULL", {}, args_row(SanitizedRow))
    _ = (
        enum_row,
        enum_array_row,
        enum_grid_row,
        leaf_row,
        leaf_array_row,
        wrapper_row,
        sanitized_row,
    )
