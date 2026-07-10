# Build Stage
FROM rust:alpine AS builder
RUN apk add --no-cache musl-dev pkgconfig openssl-dev openssl-libs-static libssh2-dev zlib-dev zlib-static
WORKDIR /app
COPY . .
RUN cargo build --release

# Final Stage
FROM alpine:latest
RUN apk add --no-cache tzdata libssh2 libgcc
COPY --from=builder /app/target/release/transfer-watcher /usr/local/bin/transfer-watcher

# Set up SSH directory
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD /usr/local/bin/transfer-watcher --health || exit 1

ENTRYPOINT ["/usr/local/bin/transfer-watcher"]
