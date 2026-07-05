"""pgenie-python-gen: the python.gen frozen Dhall generator as an installable wheel.

The wheel bundles a single build artifact, ``resolved.dhall`` (the generator with
every remote import resolved and CSE-compacted), and exposes it to a pgenie
project without a network fetch. Point a pgenie ``gen:`` at the path returned by
:func:`resolved_dhall_path` or produced by the ``vendor`` CLI verb.
"""

import importlib.resources
from pathlib import Path

from . import _meta

__version__ = _meta.version
__all__ = ["__version__", "resolved_dhall_path"]

_RESOLVED_DHALL = "resolved.dhall"


def resolved_dhall_path() -> Path:
    """Absolute path to the bundled ``resolved.dhall``.

    Raises FileNotFoundError in a source checkout, where the artifact is only
    materialized by the release build.
    """
    resource = importlib.resources.files(__name__).joinpath(_RESOLVED_DHALL)
    if not resource.is_file():
        raise FileNotFoundError(
            f"{_RESOLVED_DHALL} is not present in this pgenie_python_gen install. "
            "This is a development tree; built wheels carry the file. Install a "
            "release wheel (or build one in CI) to get the resolved generator."
        )
    # Wheels install unzipped, so the traversable is a real on-disk path.
    return Path(str(resource))
