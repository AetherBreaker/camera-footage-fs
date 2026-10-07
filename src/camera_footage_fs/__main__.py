"""The app `run-app-camera-footage-fs`: relays SFTP and the SFTPGo web client to the office PC over the tunnel.

SFTP connections get a PROXY protocol v2 header written here from the real peer address, so a
sibling on `coolify` cannot spoof one. The web port accepts only Traefik (`coolify-proxy`, checked by
reverse DNS per connection since its addresses change on restart), since SFTPGo trusts `X-Forwarded-For` from
this spoke and anything else reaching 8090 could forge it. The upstream's address is the
`UPSTREAM_PEER` row of the hub's peer table, which the supervisor caches and rewrites on every hub
release; it's read per connection so a re-addressed peer applies without a restart. The heartbeat
is a bare timestamp the devkit healthcheck reads; the supervisor owns the healthchecks.io ping.
"""

# Standard library imports
import asyncio
import contextlib
import ipaddress
import logging
import signal
import struct
import time
import tomllib
from datetime import datetime
from pathlib import Path

UPSTREAM_PEER = "cffs-pc"
PEERS_CACHE = Path("/app/persisted_data/wireguard/peers.toml")
SFTP_PORT = 2022
WEB_PORT = 8090
TRAEFIK_HOST = "coolify-proxy"
CONNECT_TIMEOUT_SECS = 10
BEAT_SECS = 60
HEARTBEAT_FILE = Path("/app/persisted_data/logs/heartbeat.txt")
PROXY_V2_SIGNATURE = b"\r\n\r\n\x00\r\nQUIT\n"

log = logging.getLogger("camera_footage_fs")


def proxy_v2_header(src: tuple[str, int], dst: tuple[str, int]) -> bytes:
  """A PROXY v2 `PROXY` command for a TCP stream from `src` to `dst`."""
  src_ip, dst_ip = ipaddress.ip_address(src[0]), ipaddress.ip_address(dst[0])
  if isinstance(src_ip, ipaddress.IPv6Address) and src_ip.ipv4_mapped:
    src_ip = src_ip.ipv4_mapped
  if isinstance(dst_ip, ipaddress.IPv6Address) and dst_ip.ipv4_mapped:
    dst_ip = dst_ip.ipv4_mapped
  if src_ip.version != dst_ip.version:
    # One address block holds one family, so a mixed pair is widened to v6.
    src_ip, dst_ip = ipaddress.IPv6Address(f"::ffff:{src_ip}"), ipaddress.IPv6Address(f"::ffff:{dst_ip}")
  family = 0x11 if isinstance(src_ip, ipaddress.IPv4Address) else 0x21  # AF_INET or AF_INET6, STREAM
  body = src_ip.packed + dst_ip.packed + struct.pack("!HH", src[1], dst[1])
  return PROXY_V2_SIGNATURE + bytes([0x21, family]) + struct.pack("!H", len(body)) + body


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> int:
  """Copy `reader` to `writer` until EOF or a reset; returns the bytes copied."""
  total = 0
  with contextlib.suppress(ConnectionError):
    while data := await reader.read(65536):
      writer.write(data)
      await writer.drain()
      total += len(data)
  return total


async def relay(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter, port: int, *, send_proxy_header: bool) -> None:
  """Open the upstream on `port`, relay both ways until either side ends, then close both and log once."""
  peer, local = client_w.get_extra_info("peername"), client_w.get_extra_info("sockname")
  started = time.monotonic()
  try:
    table = tomllib.loads(await asyncio.to_thread(PEERS_CACHE.read_text, encoding="utf-8"))
    row = next(p for p in table.get("peers", []) if p.get("name") == UPSTREAM_PEER)
    upstream = str(ipaddress.ip_interface(row["address"]).ip)
  except (OSError, ValueError, KeyError, StopIteration) as e:
    log.warning("%s:%d -> :%d refused: no address for %s in %s: %r", peer[0], peer[1], port, UPSTREAM_PEER, PEERS_CACHE, e)
    client_w.close()
    return
  try:
    up_r, up_w = await asyncio.wait_for(asyncio.open_connection(upstream, port), CONNECT_TIMEOUT_SECS)
  except (OSError, TimeoutError) as e:
    log.warning("%s:%d -> :%d upstream %s:%d unreachable: %r", peer[0], peer[1], port, upstream, port, e)
    client_w.close()
    return
  if send_proxy_header:
    up_w.write(proxy_v2_header(peer, local))
  tasks = [asyncio.create_task(pump(client_r, up_w)), asyncio.create_task(pump(up_r, client_w))]
  # Either direction ending ends the session: SFTP and HTTP don't rely on half-close here.
  await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
  for w in (up_w, client_w):
    w.close()
  for t in tasks:
    t.cancel()
  results = await asyncio.gather(*tasks, return_exceptions=True)
  sent, received = (r if isinstance(r, int) else 0 for r in results)
  log.info("%s:%d -> :%d closed after %.0fs, %d B up, %d B down", peer[0], peer[1], port, time.monotonic() - started, sent, received)


async def on_sftp(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
  """SFTP: always relay, prefixed with the client's real address."""
  await relay(reader, writer, SFTP_PORT, send_proxy_header=True)


async def on_web(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
  """Web client: relay only connections from Traefik, untouched so its `X-Forwarded-For` reaches SFTPGo."""
  peer = writer.get_extra_info("peername")
  # Reverse lookup, not forward: Coolify also joins Traefik to each project's own network and it
  # connects from there, while a forward lookup answers only its `coolify` address. Docker's DNS
  # names the container on any shared network, and container names are unique per host.
  try:
    name, _ = await asyncio.get_running_loop().getnameinfo((peer[0], 0))
  except OSError:
    name = ""
  if name.split(".")[0] != TRAEFIK_HOST:
    log.warning("%s:%d -> :%d refused: not %s", peer[0], peer[1], WEB_PORT, TRAEFIK_HOST)
    writer.close()
    return
  await relay(reader, writer, WEB_PORT, send_proxy_header=False)


async def main() -> None:
  """Serve both listeners and beat until SIGINT or SIGTERM."""
  stop = asyncio.Event()
  loop = asyncio.get_running_loop()
  for sig in (signal.SIGINT, signal.SIGTERM):
    loop.add_signal_handler(sig, stop.set)
  sftp = await asyncio.start_server(on_sftp, "0.0.0.0", SFTP_PORT)
  web = await asyncio.start_server(on_web, "0.0.0.0", WEB_PORT)
  log.info("relaying :%d and :%d to %s", SFTP_PORT, WEB_PORT, UPSTREAM_PEER)
  while not stop.is_set():
    beat = datetime.now().isoformat(timespec="seconds")  # noqa: DTZ005 - the healthcheck reads a bare timestamp as container-local
    await asyncio.to_thread(HEARTBEAT_FILE.write_text, beat, encoding="utf-8")
    with contextlib.suppress(TimeoutError):
      await asyncio.wait_for(stop.wait(), BEAT_SECS)
  for server in (sftp, web):
    server.close()
    # wait_closed() waits on open sessions; long SFTP transfers would hold shutdown until SIGKILL.
    server.close_clients()
    await server.wait_closed()


def run_app() -> None:
  """Entry point for `run-app-camera-footage-fs`."""
  logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
  HEARTBEAT_FILE.parent.mkdir(parents=True, exist_ok=True)
  asyncio.run(main())


if __name__ == "__main__":
  run_app()
