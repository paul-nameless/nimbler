FROM alpine:3.10.2 as base

WORKDIR /opt

RUN apk update && apk add --no-cache gcc musl-dev

RUN wget https://nim-lang.org/download/nim-1.0.0.tar.xz && \
    tar xf nim-1.0.0.tar.xz && cd nim-1.0.0/ && sh build.sh && \
    bin/nim c koch && ./koch tools

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/nim-1.0.0/bin

ADD server.nim main.nim

RUN nim c -d:ssl -d:release main.nim


# Final image
# ===========
FROM alpine:3.10.2
COPY --from=base /opt/main /opt/main
