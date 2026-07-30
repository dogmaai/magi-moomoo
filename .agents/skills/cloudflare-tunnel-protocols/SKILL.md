---
name: cloudflare-tunnel-protocols
description: Protocol guidance for Cloudflare tunnels used by the MAGI system (MooMoo bridge, Ollama, OpenClaw Gateway). Covers when the gRPC setting should be enabled or left disabled.
---

# Cloudflare Tunnel Protocol Settings for MAGI

## gRPC setting

The Cloudflare **gRPC** setting (`Allow gRPC connections to the origin server`) can remain **disabled** for all MAGI Cloudflare tunnels unless you explicitly add a gRPC origin.

### Why disabled is correct today

All services exposed through MAGI's Cloudflare tunnels use HTTP(S) only:

- `moomoo-bridge` (Flask, `http://localhost:11436`)
- `ollama` (HTTP REST API, `http://localhost:${OLLAMA_PORT}`)
- `openclaw-gateway` (HTTP, `http://localhost:${OPENCLAW_PORT}`)

None of the tunnel ingress definitions in `magi-moomoo/scripts/setup-*-named-tunnel.sh` declare `service: tcp://` or a gRPC endpoint. They all use `service: http://localhost:<port>` with `originRequest.httpHostHeader` when needed.

### SIGIL / OpenTelemetry note

`magi-core` sends traces and metrics to Grafana Cloud OTLP using **HTTP** exporters (`@opentelemetry/exporter-trace-otlp-http`, `@opentelemetry/exporter-metrics-otlp-http`). This traffic goes from the Cloud Run job directly to `https://otlp-gateway-prod-ap-northeast-0.grafana.net/otlp` and does not traverse the TIALA Cloudflare tunnel. Keeping the tunnel gRPC setting disabled therefore does not affect SIGIL telemetry.

### Security recommendation

Leave the setting disabled. Enabling it widens the origin protocol surface with no benefit for the current HTTP-only ingresses. If a future service genuinely requires gRPC through the tunnel, enable it only after confirming the origin supports gRPC and the tunnel route is intended for that protocol.

### References

- Cloudflare gRPC support overview: gRPC is supported via private subnet routing; public hostname deployments are not currently supported.
  - https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/grpc/
  - https://developers.cloudflare.com/network/grpc-connections/
- Tunnel ingress configuration: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/
