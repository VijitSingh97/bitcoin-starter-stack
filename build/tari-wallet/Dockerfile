FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build
WORKDIR /src
COPY --chmod=0644 build/tari-wallet/go.mod ./
COPY --chmod=0644 build/tari-wallet/launcher.go ./
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /tari-wallet-launcher .

FROM ghcr.io/tari-project/minotari_console_wallet:v6.2.0-mainnet@sha256:655e804656350559bd4338539b2c625fe2799456b5027f1c2d859d48a9c3c49e
USER 0
COPY --from=build --chmod=0755 /tari-wallet-launcher /usr/local/bin/tari-wallet-launcher
COPY --chmod=0644 build/tari-wallet/config.toml /var/tari/config/config.toml
RUN chmod 0755 /var/tari /var/tari/config && \
    mkdir -p /tari-wallet/private && chown -R 1000:1000 /tari-wallet
USER 1000:1000
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/tari-wallet-launcher"]
