# Build Stage
FROM rust:alpine AS builder
RUN apk add --no-cache musl-dev pkgconfig openssl-dev openssl-libs-static libssh2-dev zlib-dev zlib-static
WORKDIR /app
COPY . .
# Compile a fully statically linked binary
RUN RUSTFLAGS="-C target-feature=+crt-static" PKG_CONFIG_ALL_STATIC=1 cargo build --release

# Final Stage
FROM gcr.io/distroless/static-debian13:latest

# Copy the compiled binary from the builder
COPY --from=builder /app/target/release/transfer-watcher /usr/local/bin/transfer-watcher

# Healthcheck executes the binary directly since distroless has no shell
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["/usr/local/bin/transfer-watcher", "--health"]

ENTRYPOINT ["/usr/local/bin/transfer-watcher"]
