# --- Build stage ---
FROM swift:6.0-jammy AS build
WORKDIR /app

# Copy ONLY the manifest first; let Swift 6.0 resolve pins
COPY Package.swift ./
RUN swift package resolve

# Now copy sources and build
COPY . .
RUN swift build -c release --static-swift-stdlib

# --- Runtime stage ---
FROM ubuntu:22.04 AS run
WORKDIR /run
RUN apt-get update && apt-get install -y \
  ca-certificates tzdata libsqlite3-0 && \
  rm -rf /var/lib/apt/lists/*

# Binary
COPY --from=build /app/.build/release/Run /run/Run

# Static assets (optional). Keep Public since you have it.
COPY --from=build /app/Public /run/Public

# No Resources folder in your repo, so don’t copy it.
# If you later add one, you can re-add:
# COPY --from=build /app/Resources /run/Resources

EXPOSE 8080
ENV PORT=8080
ENV DATABASE_URL=""
CMD ["/run/Run", "serve", "--hostname", "0.0.0.0", "--port", "8080", "--env", "production"]
