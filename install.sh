#!/usr/bin/env bash
# Xray 一键安装脚本 (xb)
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/zen-box/xb/v1.3.3/install.sh)
# 本地测试: bash install.sh --local   (使用同目录下的 xb.sh)

REPO="${REPO:-zen-box/xb}"
TAG="${TAG:-v1.3.3}"
RAW="${RAW:-https://raw.githubusercontent.com/$REPO/$TAG}"

[[ $EUID -eq 0 ]] || { echo "请使用 root 用户运行"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "仅支持使用 systemd 的系统 (Debian/Ubuntu/CentOS 等)"; exit 1; }

echo "[1/3] 安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl jq openssl unzip iproute2 ca-certificates coreutils >/dev/null 2>&1
  apt-get install -y qrencode >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  PM=$(command -v dnf || command -v yum)
  "$PM" install -y curl jq openssl unzip iproute ca-certificates >/dev/null 2>&1
  "$PM" install -y qrencode >/dev/null 2>&1 || true
else
  echo "不支持的包管理器，请手动安装: curl jq openssl unzip iproute2"
fi

for c in curl jq openssl unzip ss; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖: $c，安装失败"; exit 1; }
done

echo "[2/3] 安装 xb 管理脚本..."
mkdir -p /etc/xray-sh
echo "$REPO" > /etc/xray-sh/repo
if [[ $1 == --local ]]; then
  cp "$(dirname "$0")/xb.sh" /usr/local/bin/xb || { echo "找不到同目录下的 xb.sh"; exit 1; }
else
  curl -fsSL -H 'Accept: application/vnd.github.raw' \
    "https://api.github.com/repos/${REPO}/contents/xb.sh?ref=${TAG}" \
    -o /usr/local/bin/xb \
    || { echo "下载 xb.sh 失败: $RAW/xb.sh"; exit 1; }
fi
chmod +x /usr/local/bin/xb

echo "[3/3] 安装 Xray 并创建默认配置..."
exec /usr/local/bin/xb first-run
