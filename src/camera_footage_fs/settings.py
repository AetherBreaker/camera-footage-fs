"""Environment-backed settings for the ingress relay."""

# Standard library imports
from typing import TYPE_CHECKING, Annotated

# Third party imports
from pydantic import Field

# First party imports
from aeth_ext.settings import BaseSettings

if TYPE_CHECKING:
  # Standard library imports
  from pathlib import Path  # property annotations only; pydantic never evaluates them


class Settings(BaseSettings):
  """The relay's tunables; every default is the deployed value."""

  # The hub peer-table row whose address the relay forwards to.
  upstream_peer: Annotated[str, Field(alias="UPSTREAM_PEER")] = "cffs-pc"
  # Each must match the compose publish (SFTP), the Coolify domain's port (web), the hub's FORWARD
  # rule and SFTPGo's bindings, which use the same port numbers on both sides.
  sftp_port: Annotated[int, Field(alias="SFTP_PORT")] = 2022
  web_port: Annotated[int, Field(alias="WEB_PORT")] = 8090
  # The only container allowed to reach the web port, since SFTPGo trusts its X-Forwarded-For.
  traefik_host: Annotated[str, Field(alias="TRAEFIK_HOST")] = "coolify-proxy"
  connect_timeout_secs: Annotated[float, Field(alias="CONNECT_TIMEOUT_SECS")] = 10
  # Must stay inside aeth-ext's 7 s graceful shutdown budget.
  close_timeout_secs: Annotated[float, Field(alias="CLOSE_TIMEOUT_SECS")] = 5
  beat_secs: Annotated[float, Field(alias="BEAT_SECS")] = 60

  @property
  def peers_cache(self) -> Path:
    """The hub's peer table, as devkit-container's supervisor caches it."""
    return self.persisted_dir_loc / "wireguard" / "peers.toml"

  @property
  def heartbeat_file(self) -> Path:
    """The file the devkit healthcheck reads."""
    return self.persisted_dir_loc / "logs" / "heartbeat.txt"


SETTINGS = Settings.get_settings()
