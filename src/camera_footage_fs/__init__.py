"""Public ingress spoke for the office SFTPGo server."""

# Standard library imports
from sys import platform

# Third party imports
from rich.console import Console

# Read by aeth-ext's logging setup. The fixed width keeps Coolify's log view legible.
RICH_CONSOLE = Console(
  width=None if platform == "win32" else 165,
  log_time=platform == "win32",
)
PROJECT_NAME = "camera-footage-fs"
