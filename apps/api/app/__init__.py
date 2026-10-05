"""OpenCaptions API package.

Single source of truth for the version the backend reports. The value is read
from the installed distribution metadata (the ``opencaptions-api`` distribution
declared in ``apps/api/pyproject.toml``) instead of a hardcoded literal, so a
release only edits ``pyproject.toml`` on the Python side. A failed lookup raises
``importlib.metadata.PackageNotFoundError`` loudly rather than reporting a
placeholder version.
"""

from importlib.metadata import version

__version__ = version("opencaptions-api")
