#!/usr/bin/env bash
# =====================================================================
# bilibili-downloader-cli 安装脚本
# 用法: bash install.sh [安装目录]   (默认 /usr/local/bin)
#
# 安装的是 Python 单文件实现 bin/bilidown.py (软链, chmod +x),
# 唯一实现, 跨平台 (Windows/macOS/Linux/iSH/Termux)。
# Windows 推荐: powershell -ExecutionPolicy Bypass -File install.ps1
# =====================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Windows (Git Bash / MSYS / Cygwin) 分支 ----------
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        INSTALL_DIR="${1:-$HOME/bin}"
        echo ">>> [Windows/Git Bash] 安装 bilidown 到 $INSTALL_DIR (wrapper)..."
        mkdir -p "$INSTALL_DIR"
        cat > "$INSTALL_DIR/bilidown" <<EOF
#!/usr/bin/env bash
exec python3 "$SELF_DIR/bin/bilidown.py" "\$@"
EOF
        chmod +x "$INSTALL_DIR/bilidown"
        cp "$SELF_DIR/bin/bilidown.cmd" "$INSTALL_DIR/bilidown.cmd" 2>/dev/null || true
        echo ">>> 完成! 把 $INSTALL_DIR 加入 PATH 后即可使用:"
        echo "    bilidown --version"
        echo ""
        echo ">>> 更推荐(自动配 PATH + bilidown.cmd 入口):"
        echo "    powershell -ExecutionPolicy Bypass -File install.ps1"
        echo "仓库位置: $SELF_DIR (wrapper 依赖它, 请勿移动)"
        exit 0
        ;;
esac

# ---------- 类 Unix: 软链安装 ----------
INSTALL_DIR="${1:-/usr/local/bin}"
echo ">>> 安装 bilidown 到 $INSTALL_DIR (软链)..."
mkdir -p "$INSTALL_DIR"

chmod +x "$SELF_DIR/bin/bilidown.py"
ln -sf "$SELF_DIR/bin/bilidown.py" "$INSTALL_DIR/bilidown"

echo ">>> 完成! 运行测试:"
echo "    bilidown --version"
echo "    bilidown --help"
echo ""
echo "仓库位置: $SELF_DIR (不要移动, 软链依赖它)"
