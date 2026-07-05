"""Build-stamped package metadata.

Overwritten by .github/workflows/release.yml before the release wheel is built;
the values committed here are development-tree defaults so the package still
imports and the CLI still runs from a plain source checkout.
"""

version = "0.0.0.dev0"
repo: str | None = None
release_url: str | None = None
