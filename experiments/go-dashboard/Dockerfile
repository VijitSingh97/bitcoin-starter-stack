FROM golang:1.27.3-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build

WORKDIR /repo/experiments/go-dashboard
COPY experiments/go-dashboard/go.mod experiments/go-dashboard/*.go experiments/go-dashboard/index.html ./
COPY build/dashboard/static /repo/build/dashboard/static
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go test ./... && \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/go-dashboard . && \
    mkdir -p /out/app/static /out/data /out/state && \
    cp index.html /out/app/index.html && \
    cp -R /repo/build/dashboard/static/. /out/app/static/ && \
    cp /etc/ssl/certs/ca-certificates.crt /out/ca-certificates.crt

FROM scratch
COPY --from=build /out/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build --chown=1000:1000 /out/app /app
COPY --from=build --chown=1000:1000 /out/data /data
COPY --from=build --chown=1000:1000 /out/state /state
COPY --from=build /out/go-dashboard /go-dashboard
USER 1000:1000
EXPOSE 8000
STOPSIGNAL SIGTERM
ENTRYPOINT ["/go-dashboard"]
