# camera-footage-fs

The public ingress for the office SFTPGo server at `cffs.sweetfiretobacco.com`. A WireGuard spoke (`10.8.0.23`) of `wireguard-hub` that relays two ports to the SFTPGo PC (`cffs-pc`, `10.8.0.22`):

- **2022, SFTP:** published directly by compose. Each connection is prefixed with a PROXY protocol v2 header carrying the client's address, so SFTPGo logs and Defender see the real IP.
- **8090, web client:** reached only by Traefik (Coolify domain `https://cffs.sweetfiretobacco.com:8090`, public on 443). Connections from any other source are refused, so no other container on `coolify` can forge `X-Forwarded-For`.

The hub forwards only `10.8.0.23` → `10.8.0.22` on TCP 2022 and 8090.

## The SFTPGo PC (`cffs-pc`)

`sftpgo/sftpgo.json` is the master copy of SFTPGo's config: v2.7.6's defaults with these changes:

- **2022, SFTP:** honours PROXY headers from `10.8.0.23` only. LAN clients without a header still connect.
- **8080, admin:** the web admin and REST API, office LAN only. No proxy header is trusted, and Windows Firewall keeps it off the tunnel.
- **8090, web client:** reached only through the ingress. The REST API is off here because it carries the admin token and password-reset endpoints. It reads the client IP from the rightmost `X-Forwarded-For` entry, which Traefik appends, and only from `10.8.0.23`.
- **Defender:** enabled.

Users, groups, folders and admins live in SFTPGo's database, not in this file, and are managed in the admin UI. Its backups hold password hashes, so they never go in this public repo.

Windows Firewall, from an administrator PowerShell. The tunnel interface is classed Public, so the tunnel rule needs every profile, and the admin rule is limited to Domain and Private to keep it off the tunnel:

```powershell
New-NetFirewallRule -DisplayName "SFTPGo via cffs ingress" -Direction Inbound -Protocol TCP -LocalPort 2022,8090 -RemoteAddress 10.8.0.23 -Profile Any -Action Allow
New-NetFirewallRule -DisplayName "SFTPGo admin (office LAN)" -Direction Inbound -Protocol TCP -LocalPort 8080 -RemoteAddress LocalSubnet -Profile Domain,Private -Action Allow
```

If the office LAN adapter is classed Public, the admin rule won't match. That fails closed: admin access is blocked, not exposed. Remove any broader rule for these ports that an installer added.

## Deploying

Coolify environment: `WG_PRIVATE_KEY`, `WG_HUB_URL=https://tunnels.sweetfiretobacco.com`, `WG_HUB_REPO=AetherBreaker/wireguard-hub`. The DNS record for `cffs` must be DNS-only, because a proxied record cannot carry TCP 2022. Open TCP 2022 in the VPS firewall.
