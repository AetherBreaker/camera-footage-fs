# camera-footage-fs

The public ingress for the office SFTPGo server at `cffs.sweetfiretobacco.com`. A WireGuard spoke (`10.8.0.23`) of `wireguard-hub` that relays two ports to the SFTPGo PC (`cffs-pc`, `10.8.0.22`):

- **2022, SFTP:** published directly by compose. Each connection is prefixed with a PROXY protocol v2 header carrying the client's address, so SFTPGo logs and Defender see the real IP.
- **8090, web client:** reached only by Traefik (Coolify domain `https://cffs.sweetfiretobacco.com:8090`, public on 443). Connections from any other source are refused, so no other container on `coolify` can forge `X-Forwarded-For`.

The hub forwards only `10.8.0.23` → `10.8.0.22` on TCP 2022 and 8090.

## Deploying

Coolify environment: `WG_PRIVATE_KEY`, `WG_HUB_URL=https://tunnels.sweetfiretobacco.com`, `WG_HUB_REPO=AetherBreaker/wireguard-hub`. The DNS record for `cffs` must be DNS-only, because a proxied record cannot carry TCP 2022. Open TCP 2022 in the VPS firewall.
