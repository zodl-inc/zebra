#!/bin/sh
# Bump every pinned StageX base image digest in Dockerfile.deterministic to the
# latest published value from the StageX release digest manifests.
#
# From ZcashFoundation/zebra PR #10068 (Anton Livaja / Distrust); adapted to
# target docker/Dockerfile.deterministic (the original targeted docker/Dockerfile).
# Run from the docker/ directory: `cd docker && ./update-stagex.sh`.
#
# Review the resulting diff carefully: per StageX's trust model, digests should
# only be advanced to versions that have been independently reproduced and
# co-signed by at least two StageX maintainers.
set -e
DOCKERFILE="Dockerfile.deterministic"
cp "$DOCKERFILE" "$DOCKERFILE.bak"
for s in core user bootstrap; do
    curl -sL https://codeberg.org/stagex/stagex/raw/branch/main/digests/$s.txt |
    while read d n; do
        sed -i "s|FROM stagex/${n}@sha256:[^ ]* AS|FROM stagex/$n@sha256:$d AS|" "$DOCKERFILE"
    done
done
rm "$DOCKERFILE.bak"
