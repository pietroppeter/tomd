FROM nimlang/nim:2.2.4-alpine AS build
WORKDIR /app
COPY src ./src
RUN nim c -d:release -d:ssl --hints:off -o:/app/tomd src/tomd.nim

FROM alpine:3.20
RUN apk add --no-cache libssl3 ca-certificates
COPY --from=build /app/tomd /usr/local/bin/tomd
ENV PORT=8000
EXPOSE 8000
CMD ["tomd"]
