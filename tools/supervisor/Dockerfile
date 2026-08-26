FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
        make curl ca-certificates xz-utils file && \
    rm -rf /var/lib/apt/lists/*
RUN curl -sSL https://musl.cc/mipsel-linux-musl-cross.tgz -o /tmp/tc.tgz && \
    tar -xzf /tmp/tc.tgz -C /opt && rm /tmp/tc.tgz
ENV PATH=/opt/mipsel-linux-musl-cross/bin:$PATH
WORKDIR /build
