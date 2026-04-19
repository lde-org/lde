FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://github.com/lde-org/lde/releases/download/nightly/lde-linux-x86-64 \
        -o /usr/local/bin/lde \
    && chmod +x /usr/local/bin/lde \
    && lde --setup
