#!/bin/sh

# Deterministic StageX build driver for Zebra.
# Originally from ZcashFoundation/zebra PR #10491 (Anton Livaja / Distrust);
# extended with the compat.sh preflight from PR #10068. Ported into
# zodl-inc/zebra (feat/stagex-reproducible, Linear COR-1293).

set -e

DIR="$( cd "$( dirname "$0" )" && pwd )"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PLATFORM="linux/amd64"
OCI_OUTPUT="$REPO_ROOT/build/oci"
DOCKERFILE="$REPO_ROOT/docker/Dockerfile.deterministic"
NAME=zebra

# Preflight: deterministic OCI output (rewrite-timestamp) requires Docker 26+,
# buildx 0.13+, and the containerd image store. compat.sh dies with guidance
# if any are missing.
if [ -x "$DIR/compat.sh" ]; then
	"$DIR/compat.sh"
fi

export DOCKER_BUILDKIT=1
export SOURCE_DATE_EPOCH=1

echo $DOCKERFILE
mkdir -p $OCI_OUTPUT

# Build runtime image for docker run
echo "Building runtime image..."
docker build -f "$DOCKERFILE" "$REPO_ROOT" \
	--platform "$PLATFORM" \
	--target runtime \
	--output type=oci,rewrite-timestamp=true,force-compression=true,dest=$OCI_OUTPUT/zebra.tar,name=zebra \
	"$@"

# Extract binary locally from export stage
echo "Extracting binary..."
docker build -f "$DOCKERFILE" "$REPO_ROOT" --quiet \
	--platform "$PLATFORM" \
	--target export \
	--output type=local,dest="$REPO_ROOT/build" \
	"$@"
