# Tailscale

Admin access is Tailscale-only.

Expected operator flow:

1. Join the same tailnet as the server.
2. Confirm `dailywerk-ops` resolves through MagicDNS.
3. Use the Tailscale path for SSH and Grafana access.

Useful commands:

```bash
tailscale status
ssh deploy@dailywerk-ops
open http://dailywerk-ops:3000
```

The server should allow all inbound traffic on `tailscale0` and expose no public SSH port.
