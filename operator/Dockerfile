# Build the thorium operator binary
FROM rust:1.81 as builder
WORKDIR /build
COPY . .
RUN rustup toolchain install nightly \
    && RUSTFLAGS="-C target-feature=+aes,+sse2" cargo +nightly build --release -p thorium-operator

# Create minimal runtime image
FROM debian:bookworm-slim
WORKDIR /app
COPY --from=builder /build/target/release/thorium-operator /usr/local/bin/thorium-operator
ENTRYPOINT ["/usr/local/bin/thorium-operator", "operate"]
