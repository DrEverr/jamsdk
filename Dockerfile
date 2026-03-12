FROM --platform=linux/amd64 debian:13-slim AS builder

# ---- System deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates curl git build-essential xz-utils \
    && rm -rf /var/lib/apt/lists/*

# ---- Rust (for polkatool, polkavm-to-jam) ----
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

# ---- C3 compiler (prebuilt Linux x86_64) ----
ARG C3_VERSION=0.7.10
RUN wget -qO /tmp/c3.tar.gz \
    "https://github.com/c3lang/c3c/releases/download/v${C3_VERSION}/c3-linux.tar.gz" \
    && mkdir -p /opt/c3 \
    && tar xzf /tmp/c3.tar.gz -C /opt/c3 --strip-components=1 \
    && rm /tmp/c3.tar.gz
ENV PATH="/opt/c3:${PATH}"

# ---- polkatool ----
ARG POLKATOOL_VERSION=0.29.0
RUN cargo install --quiet --root /opt polkatool@${POLKATOOL_VERSION}

# ---- polkavm-to-jam (patched: handles missing RO/RW sections from polkatool 0.29+) ----
COPY tools/polkavm-to-jam/ /tmp/polkavm-to-jam/
RUN cargo install --quiet --path /tmp/polkavm-to-jam --root /opt

ENV PATH="/opt/bin:${PATH}"

# ---- Verify tools ----
RUN c3c --version && polkatool --version && which polkavm-to-jam

# ==========================================================================
FROM --platform=linux/amd64 debian:13-slim AS runtime

# Install clang + lld (needed to compile host_stubs.c with PolkaVM metadata)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates clang lld \
    && rm -rf /var/lib/apt/lists/*

# Copy C3 compiler
COPY --from=builder /opt/c3 /opt/c3

# Copy Rust-built tools
COPY --from=builder /opt/bin/polkatool      /usr/local/bin/polkatool
COPY --from=builder /opt/bin/polkavm-to-jam /usr/local/bin/polkavm-to-jam

ENV PATH="/opt/c3:${PATH}"

# Copy SDK library (including host_stubs.c) and build script
COPY jamsdk.c3l/ /opt/jamsdk/jamsdk.c3l/
COPY scripts/    /opt/jamsdk/scripts/

# Make jam-build available on PATH
RUN chmod +x /opt/jamsdk/scripts/jam-build \
    && ln -s /opt/jamsdk/scripts/jam-build /usr/local/bin/jam-build

WORKDIR /app

ENTRYPOINT ["jam-build"]
CMD ["--help"]
