#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

FORCE=false
ARCH=amd64

usage() {
    cat <<EOF
USAGE: $SCRIPT_NAME [OPTIONS]

Builds the local Docker images and saves them as archives under docker_images/.

By default an image is skipped when its tag already exists locally, and an
archive is skipped when the .tgz already exists. Use --force when you have
changed source that is baked into an image (for example webapp/server code)
without bumping the image tag, since otherwise the rebuild is silently a no-op.

OPTIONS:
   -f, --force        Rebuild images and rewrite archives even if they exist.
       --arch ARCH    Target architecture: amd64 (default) or arm64.
   -h, --help         Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=true
            shift
            ;;
        --arch)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --arch requires an argument" >&2
                exit 2
            fi
            ARCH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option '$1'" >&2
            echo >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$ARCH" in
    amd64|arm64) ;;
    *)
        echo "ERROR: unsupported --arch '$ARCH' (expected amd64 or arm64)" >&2
        exit 2
        ;;
esac

for dep in docker pigz; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "ERROR: required command '$dep' not found in PATH" >&2
        exit 1
    }
done

# Save an image to a gzipped archive. Writes to a temporary file first so an
# interrupted or failed save cannot leave a truncated archive behind that later
# runs would mistake for a complete one.
save_image() {
    local image_tag="$1"
    local archive="$2"

    if [[ -f "$archive" ]] && ! $FORCE; then
        echo "Archive $archive already exists locally, skipping docker save"
        return 0
    fi

    echo "Saving $image_tag to $archive"
    if ! docker save "$image_tag" | pigz >"$archive.tmp"; then
        rm -f "$archive.tmp"
        echo "ERROR: docker save for $image_tag failed" >&2
        return 1
    fi
    mv -f "$archive.tmp" "$archive"
}

build_and_save() {
    local image_tag="$1"
    local platform="$2"
    local dockerfile="$3"
    local archive="$4"
    local display_name="$5"

    if docker image inspect "$image_tag" >/dev/null 2>&1 && ! $FORCE; then
        echo "Image $image_tag already exists locally, skipping docker buildx"
        echo "  (re-run with --force if you changed source baked into this image)"
    else
        echo "Building $display_name ($image_tag) for linux/$platform"
        if ! docker buildx build --platform "linux/$platform" -t "$image_tag" \
            --load -f "$dockerfile" .; then
            echo "ERROR: docker build for $display_name failed" >&2
            return 1
        fi
    fi

    save_image "$image_tag" "$archive"
}

docker_build() {
    # edgev3
    build_and_save "edgev3:20260928" "$ARCH" \
        "docker_images/Dockerfile.edgev3" \
        "docker_images/edgev3_20260928_$ARCH.tgz" "edgev3"

    # edgev3-nextflow
    build_and_save "edgev3-nextflow:20260908" "$ARCH" \
        "docker_images/Dockerfile.edgev3-nextflow" \
        "docker_images/edgev3-nextflow_20260908_$ARCH.tgz" "edgev3-nextflow"

    # mongodb
    build_and_save "edgev3-mongo:20260818" "$ARCH" \
        "docker_images/Dockerfile.edgev3-mongo" \
        "docker_images/edgev3-mongo_20260818_$ARCH.tgz" "edgev3-mongo"

    # nginx (pulled rather than built)
    if docker image inspect "nginx:latest" >/dev/null 2>&1 && ! $FORCE; then
        echo "Image nginx:latest already exists locally, skipping docker pull"
    else
        if ! docker pull --platform "linux/$ARCH" nginx:latest; then
            echo "ERROR: docker pull for nginx failed" >&2
            return 1
        fi
    fi
    save_image "nginx:latest" "docker_images/nginx_latest_$ARCH.tgz"
}

mkdir -p docker_images

docker_build

echo "Done. Images and archives are up to date for linux/$ARCH."
