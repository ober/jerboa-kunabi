# Dockerfile — Build kunabi in a clean environment
#
# All source repos are cloned and built inside the container under /build/mine,
# with HOME=/build so no real usernames or home directories leak into the binary.
#
# NOTE: LevelDB is a C++ library requiring libstdc++, making a pure musl static
# binary impractical. Instead, we build a dynamically linked binary with minimal
# glibc dependencies that works on most modern Linux distributions.
#
# Usage:
#   docker build -t kunabi-builder .
#   id=$(docker create kunabi-builder)
#   docker cp $id:/out/kunabi ./kunabi
#   docker rm $id

FROM ubuntu:22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

# ── System dependencies ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    ca-certificates \
    curl \
    libssl-dev \
    libncurses-dev \
    uuid-dev \
    pkg-config \
    file \
    libyaml-dev \
    libleveldb-dev \
    zlib1g-dev \
    liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Rust toolchain (for jerboa-native-rs) ────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal

ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTUP_HOME="/root/.rustup"

# Set HOME early — everything under /build so paths are clean
ENV HOME=/build
WORKDIR /build

# ── Build Chez Scheme ────────────────────────────────────────────────────────
RUN git clone --depth 1 https://github.com/ober/ChezScheme.git && \
    cd ChezScheme && \
    git submodule update --init --depth 1 && \
    ./configure --threads --disable-x11 --installprefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    cd /build && rm -rf ChezScheme

# ── Clone all dependency repos ───────────────────────────────────────────────
ARG CACHE_BUST_DEPS=0
WORKDIR /build/mine
RUN git clone --depth 1 https://github.com/ober/jerboa.git && \
    git clone --depth 1 https://github.com/ober/gherkin.git && \
    git clone --depth 1 https://github.com/ober/chez-ssl.git && \
    git clone --depth 1 https://github.com/ober/chez-https.git && \
    git clone --depth 1 https://github.com/ober/chez-leveldb.git && \
    git clone --depth 1 https://github.com/ober/chez-yaml.git && \
    git clone --depth 1 https://github.com/ober/chez-zlib.git

# ── Build Rust native library ───────────────────────────────────────────────
RUN cd /build/mine/jerboa/jerboa-native-rs && \
    grep -q '#\[cfg(feature = "duckdb")\]' src/lib.rs || \
    sed -i 's/^mod duckdb_native;/#[cfg(feature = "duckdb")]\nmod duckdb_native;/' src/lib.rs && \
    CARGO_HOME=/build/.cargo \
    RUSTFLAGS="--remap-path-prefix /build/.cargo/registry/src=crate --remap-path-prefix /build/mine=src" \
    cargo build --release --no-default-features

# ── Clone jerboa-aws ─────────────────────────────────────────────────────────
ARG CACHE_BUST=0
RUN cd /build/mine && git clone --depth 1 https://github.com/ober/jerboa-aws.git

# ── Copy kunabi source ───────────────────────────────────────────────────────
COPY . /build/mine/jerboa-kunabi

# ── Set environment for build ────────────────────────────────────────────────
ENV JERBOA_HOME=/build/mine/jerboa
ENV JERBOA_AWS_HOME=/build/mine/jerboa-aws
ENV CHEZ_LEVELDB_HOME=/build/mine/chez-leveldb
ENV CHEZ_YAML_HOME=/build/mine/chez-yaml
ENV CHEZ_ZLIB_HOME=/build/mine/chez-zlib
ENV CHEZ_HTTPS_HOME=/build/mine/chez-https
ENV CHEZ_SSL_HOME=/build/mine/chez-ssl
ENV GHERKIN_HOME=/build/mine/gherkin
ENV CHEZ_DIR=/usr/local/lib/csv10.4.0-pre-release.3/ta6le

# ── Build kunabi binary ──────────────────────────────────────────────────────
WORKDIR /build/mine/jerboa-kunabi
RUN make binary

# ── Verify ───────────────────────────────────────────────────────────────────
RUN ./kunabi help && \
    echo "--- Binary info ---" && \
    ls -lh kunabi && \
    file kunabi && \
    ldd kunabi

# ── Output ───────────────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libleveldb1d \
    libssl3 \
    zlib1g \
    liblz4-1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/mine/jerboa-kunabi/kunabi /usr/local/bin/kunabi
COPY --from=builder /build/mine/jerboa-kunabi/leveldb_shim.so /usr/local/lib/
COPY --from=builder /build/mine/jerboa-kunabi/chez_ssl_shim.so /usr/local/lib/
COPY --from=builder /build/mine/jerboa-kunabi/chez_zlib_shim.so /usr/local/lib/

ENV LD_LIBRARY_PATH=/usr/local/lib

ENTRYPOINT ["/usr/local/bin/kunabi"]
CMD ["help"]
