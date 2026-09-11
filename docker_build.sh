#!/usr/bin/env bash

set -exuo pipefail

build_and_save_if_missing() {
    local image_tag="$1"
    local platform="$2"
    local dockerfile="$3"
    local archive="$4"
    local display_name="$5"

    if docker image inspect "$image_tag" >/dev/null 2>&1; then
        echo "Image $image_tag already exists locally, skipping docker buildx"
    else
        docker buildx build --platform "$platform" -t "$image_tag" --load -f "$dockerfile" . || \
          { echo "Docker build for $display_name failed"; exit 1; }
    fi

    if [[ -f "$archive" ]]; then
        echo "Archive $archive already exists locally, skipping docker save"
    else
        docker save "$image_tag" | pigz > "$archive"
    fi
}

docker_build() {
    # edgev3 
    build_and_save_if_missing "edgev3:20260908" "linux/$ARCH" "docker_images/Dockerfile.edgev3" "docker_images/edgev3_20260908_$ARCH.tgz" "edgev3"

    # edgev3-nextflow
    build_and_save_if_missing "edgev3-nextflow:20260908" "linux/$ARCH" "docker_images/Dockerfile.edgev3-nextflow" "docker_images/edgev3-nextflow_20260908_$ARCH.tgz" "edgev3-nextflow"

    # mongodb
    build_and_save_if_missing "edgev3-mongo:20260818" "linux/$ARCH" "docker_images/Dockerfile.edgev3-mongo" "docker_images/edgev3-mongo_20260818_$ARCH.tgz" "edgev3-mongo"

    # nginx
    if docker image inspect "nginx:latest" >/dev/null 2>&1; then
        echo "Image nginx:latest already exists locally, skipping docker pull and docker save"
    else
        docker pull --platform linux/$ARCH nginx:latest || \
          { echo "Docker pull for nginx failed"; exit 1; }
        docker save nginx:latest | pigz > docker_images/nginx_latest_$ARCH.tgz
    fi
}

mkdir -p docker_images

#ARCH=arm64
#docker_build

ARCH=amd64
docker_build
