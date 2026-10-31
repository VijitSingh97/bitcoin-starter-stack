FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates=20250419~deb12u2 curl=7.88.1-10+deb12u15 && rm -rf /var/lib/apt/lists/* && \
    case "$TARGETARCH" in \
      amd64) archive=x86_64-linux-gnu; sha=43200c9f9d65ebc126ea5833ca9429e144c4b3273da6bb9f4e89fd7450ab1be9 ;; \
      arm64) archive=aarch64-linux-gnu; sha=129f55defb9045d5635566382c7b9f6fd227d4106a6fc07847a38b25ff9b29a1 ;; \
      *) exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/node.tar.gz "https://github.com/litecoin-project/litecoin/releases/download/v0.21.5.8/litecoin-0.21.5.8-${archive}.tar.gz" && \
    printf '%s  %s\n' "$sha" /tmp/node.tar.gz | sha256sum -c - && \
    tar -xzf /tmp/node.tar.gz -C /tmp && install -m 0755 /tmp/litecoin-0.21.5.8/bin/litecoind /tmp/litecoin-0.21.5.8/bin/litecoin-cli /usr/local/bin/ && rm -rf /tmp/*
COPY entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh && mkdir /data && chown 1000:1000 /data
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
