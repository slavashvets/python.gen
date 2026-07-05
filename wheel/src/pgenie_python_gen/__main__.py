"""CLI for pgenie-python-gen (``pgenie-python-gen`` / ``python -m pgenie_python_gen``).

The wheel version tracks the generator version; a packaging-only fix ships as a
``.postN`` suffix on the same generator. Standard library only, no dependencies.
"""

import argparse
import shutil
import sys
from pathlib import Path

from . import _meta, resolved_dhall_path

_VENDORED_NAME = f"python-gen-v{_meta.version}.resolved.dhall"


def _cmd_path(_args: argparse.Namespace) -> int:
    print(resolved_dhall_path())
    return 0


def _cmd_version(_args: argparse.Namespace) -> int:
    print(_meta.version)
    return 0


def _cmd_url(_args: argparse.Namespace) -> int:
    if not _meta.release_url:
        print(
            "No release URL recorded. This is a development tree; built release "
            "wheels carry the canonical download URL for their version.",
            file=sys.stderr,
        )
        return 1
    print(_meta.release_url)
    return 0


def _cmd_vendor(args: argparse.Namespace) -> int:
    source = resolved_dhall_path()
    target = Path(args.dir) / _VENDORED_NAME

    if args.check:
        if not target.is_file():
            print(f"Missing vendored copy: {target}", file=sys.stderr)
            return 1
        if source.read_bytes() != target.read_bytes():
            print(f"Vendored copy differs from the bundled generator: {target}", file=sys.stderr)
            return 1
        print(f"Up to date: {target}")
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    _print_vendor_advice(args.dir, target)
    return 0


def _print_vendor_advice(dest_dir: str, target: Path) -> None:
    gen_ref = f"{dest_dir.rstrip('/')}/{_VENDORED_NAME}"
    print(f"Vendored to {target}\n")
    print("Point your pgenie.yaml at it:\n")
    print("  artifacts:")
    print("    <your-artifact>:")
    print(f"      gen: {gen_ref}\n")
    print(
        "After upgrading, delete any older python-gen-v*.resolved.dhall you\n"
        "vendored and drop the stale freeze*.pgn.yaml key that pinned the previous\n"
        "generator, so pgn re-resolves against this version. The versioned filename\n"
        "is deliberate: a stable name would trip pgn's freeze hash-mismatch guard on\n"
        "every upgrade."
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pgenie-python-gen",
        description=(
            "Locate and vendor the bundled python.gen resolved.dhall. The wheel "
            "version tracks the generator version; packaging-only fixes use a .postN suffix."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("path", help="Print the absolute path to the bundled resolved.dhall.")
    subparsers.add_parser("url", help="Print the canonical release download URL for this version.")
    subparsers.add_parser("version", help="Print the generator version this wheel ships.")

    vendor = subparsers.add_parser(
        "vendor",
        help="Copy the bundled resolved.dhall into a project under a versioned name.",
    )
    vendor.add_argument("dir", help="Destination directory for the versioned copy.")
    vendor.add_argument(
        "--check",
        action="store_true",
        help="Byte-compare an existing vendored copy instead of writing; nonzero exit on drift.",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    handlers = {
        "path": _cmd_path,
        "url": _cmd_url,
        "version": _cmd_version,
        "vendor": _cmd_vendor,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
