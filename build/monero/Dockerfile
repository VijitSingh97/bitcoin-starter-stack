FROM debian:12.12-slim@sha256:d5d3f9c23164ea16f31852f95bd5959aad1c5e854332fe00f7b3a20fcc9f635c

ARG TARGETARCH
ARG MONERO_VERSION=0.18.5.4
ARG MONERO_AMD64_SHA256=ba2928962c101b609434bf8c1b43ad59ebe96c5525977284ca599d8bf0f02d10
ARG MONERO_ARM64_SHA256=d20d71e6522b41eb8e549c3425f7f4622c9c9a448fc7147525393fd0a6b59703

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Build tools follow Bookworm security updates instead of brittle exact versions.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl bzip2 \
    && case "$TARGETARCH" in \
         amd64) archive="monero-linux-x64-v${MONERO_VERSION}.tar.bz2"; checksum="$MONERO_AMD64_SHA256" ;; \
         arm64) archive="monero-linux-armv8-v${MONERO_VERSION}.tar.bz2"; checksum="$MONERO_ARM64_SHA256" ;; \
         *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
       esac \
    && curl --fail --show-error --location --proto '=https' --tlsv1.2 --output "/tmp/$archive" "https://downloads.getmonero.org/cli/$archive" \
    && printf '%s  %s\n' "$checksum" "/tmp/$archive" | sha256sum --check --strict \
    && mkdir /tmp/monero \
    && tar -xjf "/tmp/$archive" -C /tmp/monero --strip-components=1 \
    && install -m 0755 /tmp/monero/monerod /usr/local/bin/monerod \
    && rm -rf /tmp/monero "/tmp/$archive" /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/monero-entrypoint
COPY healthcheck.sh /usr/local/bin/monero-healthcheck
RUN chmod 0755 /usr/local/bin/monero-entrypoint /usr/local/bin/monero-healthcheck \
    && mkdir -p /data \
    && chown 1000:1000 /data

USER 1000:1000
ENTRYPOINT ["/usr/local/bin/monero-entrypoint"]
