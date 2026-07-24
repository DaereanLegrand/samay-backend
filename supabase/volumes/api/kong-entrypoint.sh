#!/bin/sh
set -e

# Wait for Kong to be ready
echo "Starting Kong..."
until kong health; do
  sleep 1
done

# Start Kong
exec /docker-entrypoint.sh kong docker-start
