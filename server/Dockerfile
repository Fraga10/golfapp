
# ----------- FASE 1: BUILD -----------
FROM dart:stable AS build

WORKDIR /app

# copy everything and fetch deps
COPY . .

RUN dart pub get --no-precompile

# compile the server into a self-contained native executable
RUN dart compile exe bin/server.dart -o server


# ----------- FASE 2: PRODUÇÃO -----------
FROM alpine:3.18

# Ensure runtime libraries and tools for healthcheck
RUN apk add --no-cache libstdc++ curl ca-certificates

WORKDIR /app

# create non-root user
RUN addgroup -S app && adduser -S -G app app

# copy the compiled executable
COPY --from=build /app/server /app/server

# set ownership and restrict permissions
RUN chown -R app:app /app && chmod +x /app/server

# switch to non-root
USER app

# default port used by the server
EXPOSE 8080

# healthcheck: ping the server's /ping endpoint
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD curl -f http://127.0.0.1:8080/ping || exit 1

# command
CMD ["/app/server"]
