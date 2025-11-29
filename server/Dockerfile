# Server Dockerfile - multi-stage for simple build
# Use official Dart SDK image to run the server
FROM dart:stable AS build
WORKDIR /app

# Copy pubspec first and get dependencies (cache layer)
COPY pubspec.* ./
RUN dart pub get

# Copy the rest of the server sources
COPY . .

# (optional) Ahead-of-time compile could be used, but we'll run with dart directly
RUN dart pub get --offline || true

# Final image
FROM dart:stable
WORKDIR /app
# Create a non-root user for better security
RUN useradd -m -u 1000 appuser || true
USER appuser

# Copy sources from build stage
COPY --from=build --chown=appuser:appuser /app /app

ENV PORT=8080
EXPOSE 8080
# Install inotify-tools for the dev watcher (only in final image)
USER root
RUN apt-get update && apt-get install -y inotify-tools && rm -rf /var/lib/apt/lists/* || true

# Make sure entrypoints are executable
RUN chmod +x /app/docker-entrypoint.sh || true
RUN chmod +x /app/dev-entrypoint.sh || true
USER appuser

# Entrypoint will run the production entrypoint by default. In dev
# mode we set DEV=1 in the compose override and run `dev-entrypoint.sh`
ENTRYPOINT ["/app/docker-entrypoint.sh"]
