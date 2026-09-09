# Deploying the Fastly MCP server for a team

Runs `@fastly/mcp` over its Streamable HTTP transport so several people can
point their MCP clients at one endpoint.

No changes to `src/` are needed — the server already speaks Streamable HTTP.
The image installs the published npm package at a pinned version, so nothing
here depends on this repository's source and upgrades are a one-line bump.

## Before you deploy: the shared-identity trade

`execute` reads `FASTLY_API_TOKEN` from the process environment, so **one
token serves every user**. Fastly's audit log will show a single identity for
the whole team, and the server writes no access log of its own. There is no
per-request credential path.

Make the shared credential as small as possible. Use a Fastly **automation
token** rather than a personal API token — it is account-level rather than
tied to a person, and supports:

- `scope: global:read` — read-only
- `services` — an allowlist of specific service IDs
- `expires_at` — an expiry, so it is not indefinitely long-lived

Deploy read-only unless you have a specific reason not to. People who need
write access can run the server locally with their own token.

## Cloud Run

```sh
# 1. Artifact Registry repo and image
gcloud artifacts repositories create fastly-mcp \
  --repository-format=docker --location=REGION
gcloud builds submit deploy/ \
  --tag REGION-docker.pkg.dev/PROJECT_ID/fastly-mcp/fastly-mcp:2.1.5

# 2. Secrets
printf '%s' "$(openssl rand -hex 32)" | \
  gcloud secrets create fastly-mcp-http-auth-token --data-file=-
printf '%s' 'YOUR_FASTLY_AUTOMATION_TOKEN' | \
  gcloud secrets create fastly-api-token --data-file=-

# 3. A service account with NO project roles, granted only secret access
gcloud iam service-accounts create fastly-mcp
for s in fastly-mcp-http-auth-token fastly-api-token; do
  gcloud secrets add-iam-policy-binding "$s" \
    --member=serviceAccount:fastly-mcp@PROJECT_ID.iam.gserviceaccount.com \
    --role=roles/secretmanager.secretAccessor
done

# 4. Edit deploy/service.yaml (PROJECT_ID, REGION, MCP_ALLOWED_HOSTS), then:
gcloud run services replace deploy/service.yaml --region REGION
gcloud run services add-iam-policy-binding fastly-mcp \
  --region REGION --member=allUsers --role=roles/run.invoker
```

Step 4's `allUsers` looks alarming but is deliberate — see *Auth header
collision* below. The server's own bearer token is the gate.

## VM

```sh
cp deploy/.env.example deploy/.env   # fill in both tokens
chmod 600 deploy/.env
MCP_HOSTNAME=mcp.example.com docker compose -f deploy/compose.yaml up -d
```

Caddy terminates TLS and fetches certificates automatically. Open only 80 and
443; the server itself stays on the internal Docker network.

## Client configuration

```json
{
  "mcpServers": {
    "fastly": {
      "type": "streamable-http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer YOUR_HTTP_AUTH_TOKEN" }
    }
  }
}
```

The exact shape varies by client. Note this is Streamable HTTP — the server's
`--http-sse` flag controls response framing *within* that transport, not the
deprecated HTTP+SSE transport.

## Things that will bite you

**`MCP_ALLOWED_HOSTS` is not optional behind a proxy.** The server validates
the `Host` header and answers `421` for anything unlisted. Upstream's
`--http-allow-host` is the one HTTP flag with no environment fallback;
`docker-entrypoint.sh` synthesizes one. List every hostname clients use,
including the `run.app` URL if you keep it.

**The service account must have no roles.** The `execute` sandbox can `fetch`
any URL with no allowlist, including the metadata server at `169.254.169.254`.
Anything the attached account can do, a caller holding the bearer token can
do. Restrict egress to `api.fastly.com` where your platform allows it.

**Concurrency, not the default.** Each concurrent `execute` spawns a ~100MB
Node subprocess (~2.1s wall time before any Fastly call) on top of a ~90MB
base. Cloud Run's default of 80 concurrent requests per instance would need
roughly 8GB. `service.yaml` sets 4.

**Auth header collision.** Cloud Run's IAM auth and the server's bearer check
both claim the `Authorization` header, and Cloud Run forwards the caller's
header to the container. Enable IAM auth and the server sees a Google ID token
instead of its own and returns 401. Gate on the server's token; use
`ingress: internal` or an IP allowlist for network-level control.

**`--encrypt-secrets` does not survive multiple instances.** Its decrypt table
is an in-memory map populated only by the process that did the encrypting
(`src/secrets.js`). With more than one replica, a value encrypted by instance A
reaches instance B as an unreversible stand-in. Pinning
`FASTLY_MCP_ENCRYPT_KEY` does not fix it. If you want the flag, set
`maxScale: "1"`.

**Load balancer timeouts.** `execute` caps at 30s. A Google Cloud HTTP(S) load
balancer defaults to a 30s backend timeout and will race it — raise it. Cloud
Run's own default (300s) and the Caddy config here (60s) are fine.

## Upgrading

Bump `FASTLY_MCP_VERSION` in the Dockerfile and the image tag in
`service.yaml`, rebuild, redeploy. Nothing here tracks this repository's
source, so upstream releases need no merge.
