#!/usr/bin/env bash
# Build the Jean Claude image and push it to Docker Hub.
#   docker login -u erikhinderer        # once, with a Docker Hub access token
#   ./scripts/publish-image.sh          # builds linux/amd64 + linux/arm64, pushes :latest and :<date>
#   ./scripts/publish-image.sh --local  # build for this machine only, no push
# Env: JC_IMAGE_REPO (default erikhinderer/jean-claude), OLLAMA_TAG (default latest)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

REPO="${JC_IMAGE_REPO:-erikhinderer/jean-claude}"
BASE_TAG="${OLLAMA_TAG:-latest}"
PLATFORMS="${JC_PLATFORMS:-linux/amd64,linux/arm64}"
LOCAL=0
[ "${1:-}" = "--local" ] && LOCAL=1

command -v docker >/dev/null || die "docker not found"
docker buildx version >/dev/null 2>&1 || die "docker buildx plugin not found (apt install docker-buildx-plugin)"

VERSION="$(date -u +%Y.%m.%d)"
REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
ARGS=(--build-arg "OLLAMA_TAG=$BASE_TAG" --build-arg "VERSION=$VERSION" --build-arg "REVISION=$REVISION"
      -t "$REPO:latest" -t "$REPO:$VERSION")

if [ "$LOCAL" = 1 ]; then
  info "building $REPO:latest for this machine (no push)"
  docker buildx build --load "${ARGS[@]}" .
  info "done — try: docker run --rm $REPO:latest ollama --version"
  exit 0
fi

# Pushing needs a logged-in Docker Hub session.
if ! docker info 2>/dev/null | grep -q '^ *Username:' && ! grep -q 'index.docker.io' "${HOME}/.docker/config.json" 2>/dev/null; then
  die "not logged in to Docker Hub — run: docker login -u ${REPO%%/*}"
fi

# Multi-platform builds need a docker-container builder. The Dockerfile has no RUN
# steps, so arm64 builds without QEMU.
if ! docker buildx inspect jc-builder >/dev/null 2>&1; then
  docker buildx create --name jc-builder --driver docker-container >/dev/null
fi

info "building + pushing $REPO:{latest,$VERSION} for $PLATFORMS (base ollama/ollama:$BASE_TAG, rev $REVISION)"
docker buildx build --builder jc-builder --platform "$PLATFORMS" --push "${ARGS[@]}" .

info "published: https://hub.docker.com/r/$REPO/tags"
