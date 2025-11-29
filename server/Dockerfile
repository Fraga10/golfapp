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

# Copy entrypoint (already present in build stage copy)
# Make sure entrypoint is executable
USER root
RUN chmod +x /app/docker-entrypoint.sh || true
USER appuser

# Entrypoint will run migrations then start the server
ENTRYPOINT ["/app/docker-entrypoint.sh"]
