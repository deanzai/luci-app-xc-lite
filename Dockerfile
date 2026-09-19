FROM alpine:3.20

ARG TARGETARCH=amd64
ARG XRAY_VERSION=v24.11.30
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""

ENV http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    XC_DATA_DIR=/etc/xc \
    XRAY_LOCATION_ASSET=/usr/local/share/xray \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai

WORKDIR /app

RUN apk add --no-cache python3 curl bash ca-certificates tzdata unzip && \
    mkdir -p /usr/local/share/xray /defaults /etc/xc

# Download and install Xray Core + Loyalsoldier DAT rule assets
RUN set -ex; \
    ARCH="64"; \
    SYS_ARCH="$(uname -m)"; \
    if [ "${TARGETARCH}" = "arm64" ] || [ "${SYS_ARCH}" = "aarch64" ]; then ARCH="arm64-v8a"; fi; \
    if [ "${TARGETARCH}" = "arm" ] || [ "${SYS_ARCH}" = "armv7l" ]; then ARCH="arm32-v7a"; fi; \
    echo "Fetching Xray-core ${XRAY_VERSION} for ${ARCH} (SYS: ${SYS_ARCH}, TARGET: ${TARGETARCH})..."; \
    curl -sSL --retry 3 -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH}.zip"; \
    unzip -q /tmp/xray.zip -d /tmp/xray; \
    mv /tmp/xray/xray /usr/local/bin/xray; \
    chmod +x /usr/local/bin/xray; \
    if [ -f /tmp/xray/geoip.dat ]; then mv /tmp/xray/geoip.dat /usr/local/share/xray/; fi; \
    if [ -f /tmp/xray/geosite.dat ]; then mv /tmp/xray/geosite.dat /usr/local/share/xray/; fi; \
    rm -rf /tmp/xray.zip /tmp/xray; \
    # Fetch Loyalsoldier enhanced geoip & geosite rules \
    curl -sSL --retry 3 -o /usr/local/share/xray/geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" || true; \
    curl -sSL --retry 3 -o /usr/local/share/xray/geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || true

# Copy application files
COPY docker/app /app
COPY docker/defaults /defaults

# Setup CLI wrapper
RUN chmod +x /app/xc_cli.py && \
    ln -sf /app/xc_cli.py /usr/local/bin/xc

# Clean up proxy environment variables
ENV http_proxy="" https_proxy="" all_proxy=""

EXPOSE 7890 10809 7891

VOLUME ["/etc/xc"]

ENTRYPOINT ["python3", "/app/main.py"]
