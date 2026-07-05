"""Local, offline smoke test for the pgenie-python-gen wheel channel.

No PostgreSQL and no network at test time: it builds the wheel against a dummy
resolved.dhall with known bytes, installs it into a throwaway venv, and drives
the CLI verbs. The real resolved.dhall only exists in the release build, so a
placeholder is the only way to exercise this locally.

Run it standalone (it is not collected by the repo-root harness):

    uv run --with pytest python -m pytest wheel/tests/test_cli.py -v

The build step (`uv build`) may fetch the hatchling backend and a CPython on a
cold cache; that is the only network touch, and it is outside the CLI under test.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

_WHEEL_DIR = Path(__file__).resolve().parents[1]
_REPO_ROOT = _WHEEL_DIR.parent
_DUMMY_BYTES = b"DUMMY-RESOLVED-DHALL-BYTES\n"
_VERSION = "1.2.3"
_RELEASE_URL = f"https://github.com/example/python-gen/releases/download/v{_VERSION}/resolved.dhall"

_META = f'''version = "{_VERSION}"
repo: str | None = "example/python-gen"
release_url: str | None = "{_RELEASE_URL}"
'''

_UV = shutil.which("uv")
pytestmark = pytest.mark.skipif(_UV is None, reason="uv is required to build and install the wheel")


@pytest.fixture(scope="module")
def cli(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Build the wheel from a dummy generator, install it, return the console-script path."""
    work = tmp_path_factory.mktemp("wheel-channel")
    staged = work / "wheel"
    shutil.copytree(_WHEEL_DIR, staged, ignore=shutil.ignore_patterns("dist", "__pycache__"))
    (staged / "src" / "pgenie_python_gen" / "resolved.dhall").write_bytes(_DUMMY_BYTES)
    (staged / "src" / "pgenie_python_gen" / "_meta.py").write_text(_META)
    shutil.copyfile(_REPO_ROOT / "LICENSE", staged / "LICENSE")

    dist = work / "dist"
    subprocess.run([_UV, "build", "--sdist", "--wheel", "--out-dir", str(dist), str(staged)], check=True)

    wheels = list(dist.glob("*.whl"))
    sdists = list(dist.glob("*.tar.gz"))
    assert len(wheels) == 1 and len(sdists) == 1, dist

    venv = work / "venv"
    subprocess.run([_UV, "venv", str(venv)], check=True)
    subprocess.run([_UV, "pip", "install", "--python", str(venv / "bin" / "python"), str(wheels[0])], check=True)
    return venv / "bin" / "pgenie-python-gen"


def _run(cli: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(cli), *args], capture_output=True, text=True)


def test_version(cli: Path) -> None:
    result = _run(cli, "version")
    assert result.returncode == 0
    assert result.stdout.strip() == _VERSION


def test_url(cli: Path) -> None:
    result = _run(cli, "url")
    assert result.returncode == 0
    assert result.stdout.strip() == _RELEASE_URL


def test_path_points_at_bundled_bytes(cli: Path) -> None:
    result = _run(cli, "path")
    assert result.returncode == 0
    bundled = Path(result.stdout.strip())
    assert bundled.is_absolute()
    assert bundled.read_bytes() == _DUMMY_BYTES


def test_vendor_writes_versioned_copy(cli: Path, tmp_path: Path) -> None:
    dest = tmp_path / "vendor"
    result = _run(cli, "vendor", str(dest))
    assert result.returncode == 0
    copy = dest / f"python-gen-v{_VERSION}.resolved.dhall"
    assert copy.read_bytes() == _DUMMY_BYTES
    assert "freeze" in result.stdout


def test_vendor_check_detects_drift(cli: Path, tmp_path: Path) -> None:
    dest = tmp_path / "vendor"
    assert _run(cli, "vendor", str(dest)).returncode == 0
    assert _run(cli, "vendor", "--check", str(dest)).returncode == 0

    (dest / f"python-gen-v{_VERSION}.resolved.dhall").write_bytes(b"tampered\n")
    drift = _run(cli, "vendor", "--check", str(dest))
    assert drift.returncode != 0


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
