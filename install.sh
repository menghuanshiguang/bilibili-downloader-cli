#!/usr/bin/env bash
# =====================================================================
# bilibili-downloader-cli 安装脚本
# 用法: bash install.sh [安装目录]   (默认 /usr/local/bin)
#
# 用软链安装: bin/bilidown 解析真实路径回仓库, lib/ 相对位置始终正确
# =====================================================================
set -euo pipefail

INSTALL_DIR="${1:-/usr/local/bin}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">>> 安装 bilidown 到 $INSTALL_DIR (软链)..."
mkdir -p "$INSTALL_DIR"

ln -sf "$SELF_DIR/bin/bilidown" "$INSTALL_DIR/bilidown"
chmod +x "$SELF_DIR/bin/bilidown"

echo ">>> 完成! 运行测试:"
echo "    bilidown --version"
echo "    bilidown --help"
echo ""
echo "仓库位置: $SELF_DIR (不要移动, 软链依赖它)"
