#!/bin/bash
set -e

WRAPPER_PATH="/usr/local/bin/xc"

echo "==> Installing host wrapper script to $WRAPPER_PATH..."

if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO=""
fi

$SUDO bash -c "cat <<'EOF' > $WRAPPER_PATH
#!/bin/sh
if docker ps --format '{{.Names}}' | grep -q '^xc$'; then
    if [ -t 0 ]; then
        docker exec -it xc xc \"\$@\"
    else
        docker exec -i xc xc \"\$@\"
    fi
else
    echo \"Error: Docker container 'xc' is not running.\"
    echo \"Start it with: docker compose up -d\"
    exit 1
fi
EOF"

$SUDO chmod +x "$WRAPPER_PATH"
echo "==> Installation complete! You can now run 'xc' directly from your host shell."
echo "    Example: xc list, xc 1, xc status, xc test"
