FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build
WORKDIR /src
COPY build/dashboard/go.mod build/dashboard/go.sum ./
RUN go mod download
COPY build/dashboard/*.go ./
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /dashboard .

FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
WORKDIR /app
COPY --from=build /dashboard ./dashboard
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY build/dashboard/index.html ./index.html
COPY build/dashboard/static ./static
COPY VERSION ./VERSION
COPY build/dashboard/THIRD_PARTY_NOTICES ./THIRD_PARTY_NOTICES
RUN mkdir -p /state /tari-wallet && chown 1000:1000 /state /tari-wallet
USER 1000:1000
EXPOSE 8000
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/dashboard"]
