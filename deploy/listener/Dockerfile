FROM node:22-alpine AS build

WORKDIR /listener

RUN corepack enable

COPY deploy/listener/package.json deploy/listener/pnpm-lock.yaml deploy/listener/tsconfig.json ./
RUN pnpm install --frozen-lockfile

COPY deploy/listener/server.ts ./server.ts
RUN pnpm run build

FROM node:22-alpine

ARG OP_VERSION=2.31.1

RUN apk add --no-cache bash curl docker-cli jq unzip util-linux && \
    mkdir -p /usr/local/lib/docker/cli-plugins && \
    ARCH="$(apk --print-arch)" && \
    case "${ARCH}" in \
      x86_64) OP_ARCH=amd64 ;; \
      aarch64) OP_ARCH=arm64 ;; \
      *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
    esac && \
    case "${ARCH}" in \
      x86_64) COMPOSE_ARCH=x86_64 ;; \
      aarch64) COMPOSE_ARCH=aarch64 ;; \
      *) echo "Unsupported architecture for Docker Compose: ${ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose && \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose && \
    curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_${OP_ARCH}_v${OP_VERSION}.zip" -o /tmp/op.zip && \
    unzip /tmp/op.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/op && \
    rm -f /tmp/op.zip

WORKDIR /deploy

COPY deploy/listener /deploy/listener
COPY --from=build /listener/dist/server.js /deploy/listener/server.js

ENTRYPOINT ["node", "/deploy/listener/server.js"]
