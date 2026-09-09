# syntax=docker/dockerfile:1

# This image installs the published package rather than building from this
# repository, so upgrading is a one-line bump here and the checkout stays a
# clean mirror of upstream. Build with deploy/ as the context:
#
#   docker build -t fastly-mcp deploy/
#
ARG FASTLY_MCP_VERSION=2.1.5
ARG NODE_IMAGE=node:22-slim

FROM ${NODE_IMAGE} AS deps
ARG FASTLY_MCP_VERSION
WORKDIR /opt/fastly-mcp
RUN npm install --omit=dev --no-audit --no-fund "@fastly/mcp@${FASTLY_MCP_VERSION}"

FROM ${NODE_IMAGE}
ARG FASTLY_MCP_VERSION
LABEL org.opencontainers.image.title="fastly-mcp" \
      org.opencontainers.image.description="Fastly MCP server over Streamable HTTP" \
      org.opencontainers.image.version="${FASTLY_MCP_VERSION}" \
      org.opencontainers.image.source="https://github.com/fastly/mcp"

ENV NODE_ENV=production \
    PATH="/opt/fastly-mcp/node_modules/.bin:${PATH}"

COPY --from=deps /opt/fastly-mcp /opt/fastly-mcp
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

# `execute` spawns a subprocess per call that runs model-supplied JavaScript.
# It should never run as root.
USER node

# Overridden by PORT on Cloud Run; this is the default for a plain
# `docker run` or a VM.
EXPOSE 8231

# /healthz answers before both the auth and Host checks, so a probe needs no
# credentials. node:22-slim ships no curl, so use Node's global fetch.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||8231)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
