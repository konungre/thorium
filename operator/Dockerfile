# Build the thorium operator binary
FROM rust:1.91 as builder
WORKDIR /build
COPY . .
RUN RUSTFLAGS="-C target-feature=+aes,+sse2" cargo +nightly build --release -p thorium-operator

# Create minimal runtime image
FROM debian:bookworm-slim
WORKDIR /app
COPY --from=builder /build/target/release/thorium-operator /usr/local/bin/thorium-operator
ENTRYPOINT ["/usr/local/bin/thorium-operator", "operate"]
