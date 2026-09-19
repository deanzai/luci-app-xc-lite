#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

IMAGE_NAME="xc:latest"
CONTAINER_NAME="xc"

cmd="${1:-up}"
PROXY_PARAM="${2:-}"

# Detect or specify proxy
DETECTED_PROXY="${PROXY_PARAM:-${HTTP_PROXY:-${http_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}"

if [ -z "$DETECTED_PROXY" ]; then
    # Auto-detect common LAN proxy (e.g. 192.168.6.1:7890)
    if curl -s --connect-timeout 1 http://192.168.6.1:7890 >/dev/null 2>&1; then
        DETECTED_PROXY="http://192.168.6.1:7890"
        echo "==> Auto-detected LAN proxy at http://192.168.6.1:7890"
    fi
fi

PROXY_ARGS=""
if [ -n "$DETECTED_PROXY" ]; then
    echo "==> Using proxy for build: $DETECTED_PROXY"
    export HTTP_PROXY="$DETECTED_PROXY"
    export HTTPS_PROXY="$DETECTED_PROXY"
    export ALL_PROXY="$DETECTED_PROXY"
    export http_proxy="$DETECTED_PROXY"
    export https_proxy="$DETECTED_PROXY"
    export all_proxy="$DETECTED_PROXY"
    PROXY_ARGS="--build-arg HTTP_PROXY=$DETECTED_PROXY --build-arg HTTPS_PROXY=$DETECTED_PROXY --build-arg ALL_PROXY=$DETECTED_PROXY"
else
    echo "==> No proxy configured. If GitHub is slow or blocked, run:"
    echo "    ./build-docker.sh $cmd http://192.168.6.1:7890"
fi

case "$cmd" in
    build)
        echo "==> Building Docker image: $IMAGE_NAME ..."
        docker build $PROXY_ARGS -t "$IMAGE_NAME" .
        echo "==> Build successful: $IMAGE_NAME"
        ;;

    up|start)
        mkdir -p /etc/xc
        if [ ! -d "/etc/xc" ] || [ ! -w "/etc/xc" ]; then
            echo "Notice: /etc/xc is not directly writable without sudo, falling back to ./data"
            mkdir -p ./data
            sed -i 's|/etc/xc:/etc/xc|./data:/etc/xc|g' docker-compose.yml || true
        fi
        echo "==> Starting container $CONTAINER_NAME via docker compose..."
        docker compose up -d --build
        echo "==> XC Service started successfully!"
        echo "    Web Dashboard:  http://127.0.0.1:7891"
        echo "    SOCKS5 Proxy:   0.0.0.0:7890"
        echo "    HTTP Proxy:     0.0.0.0:10809"
        ;;
    down|stop)
        echo "==> Stopping container $CONTAINER_NAME..."
        docker compose down
        ;;
    restart)
        echo "==> Restarting container $CONTAINER_NAME..."
        docker compose restart
        ;;
    logs)
        docker compose logs -f
        ;;
    save)
        echo "==> Exporting $IMAGE_NAME to xc-docker-latest.tar.gz ..."
        docker save "$IMAGE_NAME" | gzip > xc-docker-latest.tar.gz
        echo "==> Export complete: $(pwd)/xc-docker-latest.tar.gz ($(du -h xc-docker-latest.tar.gz | awk '{print $1}'))"
        echo "    To load on another server: docker load -i xc-docker-latest.tar.gz"
        ;;
    cli)
        shift
        docker exec -it "$CONTAINER_NAME" xc "$@"
        ;;
    *)
        echo "Usage: $0 {build|up|down|restart|logs|save|cli <args>}"
        exit 1
        ;;
esac
