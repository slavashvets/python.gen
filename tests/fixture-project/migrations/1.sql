-- Type surface fixture for the Python generator.
-- Domain idioms exercised: display_name, revision, jsonb_object. Exercises every
-- scalar, array, enum, composite and domain shape the generator must map to
-- Python.

create type mood as enum ('happy', 'sad', 'meh');

create type z_codec_payload as (
  "class" int8,
  pg_decode text,
  pg_encode text
);

create type a_codec_wrapper as (
  payload z_codec_payload,
  feeling mood,
  note text
);

create type point2d as (
  x float8,
  y float8
);

-- pgn flattens domains to their base type in result columns; domain-typed query
-- parameters must be cast to the base type (pgn cannot bind a domain
-- parameter directly).
create domain display_name as text
  not null
  check (value = btrim(value))
  check (value <> '');

create domain revision as integer
  check (value >= 1);

create domain jsonb_object as jsonb
  check (jsonb_typeof(value) = 'object');

-- Single-field composite fixture: exercises the composite-bind edge case where
-- a one-field tuple literal needs a trailing comma to stay a tuple in Python
-- (point2d's two-field tuple never needed one, so its golden never exercised
-- this path).
create type tag_value as (
  value text
);

create table tagged_item (
  id   int8 primary key generated always as identity,
  name text not null,
  tag  tag_value not null
);

create table specimen (
  id            int8 primary key generated always as identity,
  pub_id        uuid not null default gen_random_uuid(),

  -- scalars, not null
  flag          bool not null,
  small         int2 not null,
  medium        int4 not null,
  large         int8 not null,
  ratio         float4 not null,
  precise       float8 not null,
  title         text not null,
  code          varchar(32) not null,
  letter        bpchar(1) not null,
  born_on       date not null,
  created_at    timestamptz not null default now(),
  amount        numeric(12, 2) not null,
  blob          bytea not null,
  doc_json      json not null,
  doc_jsonb     jsonb not null,

  -- nullable scalars across several types
  maybe_text    text,
  maybe_int     int4,
  maybe_uuid    uuid,
  maybe_ts      timestamptz,
  maybe_num     numeric(12, 2),

  -- arrays
  tags          text[] not null default '{}',
  related_ids   uuid[],
  grid          int4[][],

  -- enum
  feeling       mood not null,

  -- enum array (nullable column, nullable elements: exercises both decode guards)
  moods         mood[],

  -- composite
  origin        point2d,
  codec_payload z_codec_payload not null,
  codec_payloads z_codec_payload[] not null,
  codec_wrapper a_codec_wrapper,

  -- domains
  label         display_name not null,
  rev           revision not null default 1,
  meta          jsonb_object not null default '{}'::jsonb
);

create index specimen_by_feeling on specimen (feeling, id);
