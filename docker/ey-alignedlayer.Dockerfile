# EY Aligned Layer Operator Dockerfile
# Self-contained build - no external base image required
# Builds the operator for testnet or mainnet environments
# Versions are automatically extracted from the Makefile

# ==============================================================================
# Stage 1: Base system with Go and Rust
# ==============================================================================
FROM debian:bookworm-slim AS base

ARG BUILDARCH=amd64
ENV GO_VERSION=1.22.2

RUN apt update -y && apt upgrade -y && \
    apt install -y wget tar curl git make clang gcc g++ \
                   pkg-config openssl libssl-dev yq jq && \
    apt clean -y && rm -rf /var/lib/apt/lists/*

# Install Go
RUN wget https://golang.org/dl/go${GO_VERSION}.linux-${BUILDARCH}.tar.gz && \
    tar -C /usr/local -xzf go${GO_VERSION}.linux-${BUILDARCH}.tar.gz && \
    rm go${GO_VERSION}.linux-${BUILDARCH}.tar.gz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# Install Go dependencies
RUN go install github.com/maoueh/zap-pretty@v0.3.0 && \
    go install github.com/ethereum/go-ethereum/cmd/abigen@v1.14.0

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

WORKDIR /aligned_layer

# ==============================================================================
# Stage 2: Cargo chef planner (for Rust dependency caching)
# ==============================================================================
FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef

FROM chef AS planner

# SP1 library
COPY operator/sp1/lib/Cargo.toml /aligned_layer/operator/sp1/lib/Cargo.toml
COPY operator/sp1/lib/src/ /aligned_layer/operator/sp1/lib/src/
WORKDIR /aligned_layer/operator/sp1/lib
RUN cargo chef prepare --recipe-path /aligned_layer/operator/sp1/lib/recipe.json

# RISC Zero library
COPY operator/risc_zero/lib/Cargo.toml /aligned_layer/operator/risc_zero/lib/Cargo.toml
COPY operator/risc_zero/lib/src/ /aligned_layer/operator/risc_zero/lib/src/
WORKDIR /aligned_layer/operator/risc_zero/lib
RUN cargo chef prepare --recipe-path /aligned_layer/operator/risc_zero/lib/recipe.json

# Merkle tree library
COPY operator/merkle_tree/lib/Cargo.toml /aligned_layer/operator/merkle_tree/lib/Cargo.toml
COPY operator/merkle_tree/lib/src/ /aligned_layer/operator/merkle_tree/lib/src/
WORKDIR /aligned_layer/operator/merkle_tree/lib
RUN cargo chef prepare --recipe-path /aligned_layer/operator/merkle_tree/lib/recipe.json

# ==============================================================================
# Stage 3: Cargo chef builder (builds Rust dependencies)
# ==============================================================================
FROM chef AS chef_builder

COPY crates/sdk /aligned_layer/crates/sdk/

# Build SP1 dependencies
COPY operator/sp1/ /aligned_layer/operator/sp1/
COPY --from=planner /aligned_layer/operator/sp1/lib/recipe.json /aligned_layer/operator/sp1/lib/recipe.json
WORKDIR /aligned_layer/operator/sp1/lib/
RUN cargo chef cook --release --recipe-path /aligned_layer/operator/sp1/lib/recipe.json

# Build RISC Zero dependencies
COPY operator/risc_zero/ /aligned_layer/operator/risc_zero/
COPY --from=planner /aligned_layer/operator/risc_zero/lib/recipe.json /aligned_layer/operator/risc_zero/lib/recipe.json
WORKDIR /aligned_layer/operator/risc_zero/lib/
RUN cargo chef cook --release --recipe-path /aligned_layer/operator/risc_zero/lib/recipe.json

# Build Merkle tree dependencies
COPY operator/merkle_tree/ /aligned_layer/operator/merkle_tree/
COPY --from=planner /aligned_layer/operator/merkle_tree/lib/recipe.json /aligned_layer/operator/merkle_tree/lib/recipe.json
WORKDIR /aligned_layer/operator/merkle_tree/lib/
RUN cargo chef cook --release --recipe-path /aligned_layer/operator/merkle_tree/lib/recipe.json

# ==============================================================================
# Stage 4: Build FFI libraries and Go operator
# ==============================================================================
FROM base AS builder

ARG ENVIRONMENT=testnet

ENV RELEASE_FLAG=--release
ENV TARGET_REL_PATH=release

WORKDIR /aligned_layer

# Copy Makefile to extract versions
COPY Makefile .

# Extract versions from Makefile
RUN OPERATOR_VERSION=$(grep '^OPERATOR_VERSION=' Makefile | cut -d'=' -f2) && \
    echo "OPERATOR_VERSION=${OPERATOR_VERSION}" > /tmp/versions.env && \
    if [ "$ENVIRONMENT" = "mainnet" ]; then \
        EIGEN_SDK_VERSION=$(grep '^EIGEN_SDK_GO_VERSION_MAINNET=' Makefile | cut -d'=' -f2); \
    else \
        EIGEN_SDK_VERSION=$(grep '^EIGEN_SDK_GO_VERSION_TESTNET=' Makefile | cut -d'=' -f2); \
    fi && \
    echo "EIGEN_SDK_VERSION=${EIGEN_SDK_VERSION}" >> /tmp/versions.env && \
    echo "ENVIRONMENT=${ENVIRONMENT}" >> /tmp/versions.env && \
    echo "=== Build Configuration ===" && cat /tmp/versions.env

# Copy operator source and cached Rust build artifacts
COPY operator/ /aligned_layer/operator/
COPY crates/ /aligned_layer/crates/
COPY --from=chef_builder /aligned_layer/crates/sdk /aligned_layer/crates/sdk

# Build SP1 FFI library
COPY --from=chef_builder /aligned_layer/operator/sp1/lib/target/ /aligned_layer/operator/sp1/lib/target/
WORKDIR /aligned_layer/operator/sp1/lib
RUN cargo build ${RELEASE_FLAG} && \
    cp target/${TARGET_REL_PATH}/libsp1_verifier_ffi.so ./libsp1_verifier_ffi.so

# Build RISC Zero FFI library
COPY --from=chef_builder /aligned_layer/operator/risc_zero/lib/target/ /aligned_layer/operator/risc_zero/lib/target/
WORKDIR /aligned_layer/operator/risc_zero/lib
RUN cargo build ${RELEASE_FLAG} && \
    cp target/${TARGET_REL_PATH}/librisc_zero_verifier_ffi.so ./librisc_zero_verifier_ffi.so

# Build Merkle tree FFI library
COPY --from=chef_builder /aligned_layer/operator/merkle_tree/lib/target/ /aligned_layer/operator/merkle_tree/lib/target/
WORKDIR /aligned_layer/operator/merkle_tree/lib
RUN cargo build ${RELEASE_FLAG} && \
    cp target/${TARGET_REL_PATH}/libmerkle_tree.so ./libmerkle_tree.so

# Build Go operator
WORKDIR /aligned_layer

# Copy Go module files and set EigenSDK version
COPY go.mod go.sum ./
RUN . /tmp/versions.env && \
    echo "Setting EigenSDK to ${EIGEN_SDK_VERSION}" && \
    go get github.com/Layr-Labs/eigensdk-go@${EIGEN_SDK_VERSION} && \
    go mod download

# Copy remaining Go source
COPY core/       ./core/
COPY metrics/    ./metrics/
COPY common/     ./common/
COPY aggregator/ ./aggregator/
COPY contracts/bindings/ ./contracts/bindings/

# Set FFI library paths for build
ENV LD_LIBRARY_PATH="/aligned_layer/operator/risc_zero/lib:/aligned_layer/operator/sp1/lib:/aligned_layer/operator/merkle_tree/lib"

# Build operator binary
RUN . /tmp/versions.env && \
    echo "Building operator version ${OPERATOR_VERSION}" && \
    go build -ldflags "-X main.Version=${OPERATOR_VERSION}" \
    -o /aligned_layer/aligned-layer-operator ./operator/cmd/main.go

# ==============================================================================
# Stage 5: Runtime image (minimal)
# ==============================================================================
FROM debian:bookworm-slim

WORKDIR /aligned_layer

RUN apt update -y && \
    apt install -y libssl-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy operator binary
COPY --from=builder /aligned_layer/aligned-layer-operator /usr/local/bin/aligned-layer-operator

# Copy FFI libraries
COPY --from=builder /aligned_layer/operator/risc_zero/lib/librisc_zero_verifier_ffi.so ./operator/risc_zero/lib/
COPY --from=builder /aligned_layer/operator/sp1/lib/libsp1_verifier_ffi.so ./operator/sp1/lib/
COPY --from=builder /aligned_layer/operator/merkle_tree/lib/libmerkle_tree.so ./operator/merkle_tree/lib/

# Copy config files and contracts
COPY config-files/ ./config-files/
COPY contracts/ ./contracts/

# Set library path for runtime
ENV LD_LIBRARY_PATH="/aligned_layer/operator/risc_zero/lib:/aligned_layer/operator/sp1/lib:/aligned_layer/operator/merkle_tree/lib"

# Copy version info for inspection
COPY --from=builder /tmp/versions.env /etc/aligned-operator-versions.env

# Labels
ARG ENVIRONMENT=testnet
LABEL org.opencontainers.image.title="EY Aligned Layer Operator"
LABEL org.opencontainers.image.description="Aligned Layer Operator for ${ENVIRONMENT}"
LABEL org.opencontainers.image.source="https://github.com/yetanotherco/aligned_layer"

ENTRYPOINT ["aligned-layer-operator"]
CMD ["start", "--config", "./config-files/config-operator-docker.yaml"]
