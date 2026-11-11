# Caddy with the Route53 DNS-01 plugin. Built once on the PC by scripts/publish-template.sh and staged in
# S3 (dr/artifacts/caddy-route53.tar.gz), so recovery does not need a Go build or any module downloads.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/route53
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
