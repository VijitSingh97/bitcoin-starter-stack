FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
# netcat is only used by the compose healthcheck
RUN apk add --no-cache tor netcat-openbsd
COPY torrc /etc/tor/torrc
RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor
USER tor
ENTRYPOINT ["tor"]
CMD ["-f", "/etc/tor/torrc"]
