# syntax=docker/dockerfile:1.10
FROM alpine:3.21 AS builder

RUN apk add --no-cache gcc musl-dev make sccache

WORKDIR /build
COPY main.c httpserver.h Makefile ./

ENV SCCACHE_DIR=/tmp/sccache

# the cache url carries a password: a build secret, never an ARG or ENV baked into the image
RUN --mount=type=secret,id=sccache_redis,env=SCCACHE_REDIS \
    if [ -n "$SCCACHE_REDIS" ]; then \
    CC="sccache gcc" make; \
    else \
    make; \
    fi

FROM alpine:3.21
RUN apk add --no-cache curl
COPY --from=builder /build/server /server
EXPOSE 8000
ENTRYPOINT ["/server"]
