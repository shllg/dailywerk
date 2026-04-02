FROM docker.io/docker:27-cli

ARG OP_VERSION=2.31.1

RUN apk add --no-cache bash curl jq python3 unzip util-linux && \
    ARCH="$(apk --print-arch)" && \
    case "${ARCH}" in \
      x86_64) OP_ARCH=amd64 ;; \
      aarch64) OP_ARCH=arm64 ;; \
      *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_${OP_ARCH}_v${OP_VERSION}.zip" -o /tmp/op.zip && \
    unzip /tmp/op.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/op && \
    rm -f /tmp/op.zip

WORKDIR /deploy

COPY deploy /deploy

ENTRYPOINT ["python3", "/deploy/listener/server.py"]
