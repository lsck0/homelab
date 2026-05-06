FROM alpine:3.21 AS builder

RUN apk add --no-cache gcc musl-dev make sccache

WORKDIR /build
COPY main.c Makefile .

ARG SCCACHE_REDIS
ENV SCCACHE_REDIS=${SCCACHE_REDIS}
ENV SCCACHE_DIR=/tmp/sccache

RUN if [ -n "$SCCACHE_REDIS" ]; then \
      CC="sccache gcc" make; \
    else \
      make; \
    fi

FROM alpine:3.21
RUN apk add --no-cache curl
COPY --from=builder /build/server /server
EXPOSE 8000
ENTRYPOINT ["/server"]
