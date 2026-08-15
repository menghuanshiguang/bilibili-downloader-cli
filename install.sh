#!/usr/bin/env bash
# =====================================================================
# bilibili-downloader-cli 安装脚本
# 用法: bash install.sh [安装目录]   (默认 /usr/local/bin)
#
# 用软链安装: bin/bilidown 解析真实路径回仓库, lib/ 相对位置始终正确
# Windows (Git Bash / MSYS): 自动分支, 生成 wrapper 到 ~/bin (默认),
# 也可直接运行 install.ps1 把仓库 bin/ 加入 PATH 并使用 bilidown.cmd
# =====================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Windows (Git Bash / MSYS / Cygwin) 分支 ----------
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        INSTALL_DIR="${1:-$HOME/bin}"
        echo ">>> [Windows/Git Bash] 安装 bilidown 到 $INSTALL_DIR (wrapper)..."
        mkdir -p "$INSTALL_DIR"
        # Git Bash 的 ln -s 默认是复制, 会破坏 lib/ 相对路径, 所以用 wrapper 指向仓库绝对路径
        cat > "$INSTALL_DIR/bilidown" <<EOF
#!/usr/bin/env bash
exec bash "$SELF_DIR/bin/bilidown" "\$@"
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

ln -sf "$SELF_DIR/bin/bilidown" "$INSTALL_DIR/bilidown"
chmod +x "$SELF_DIR/bin/bilidown"

echo ">>> 完成! 运行测试:"
echo "    bilidown --version"
echo "    bilidown --help"
echo ""
echo "仓库位置: $SELF_DIR (不要移动, 软链依赖它)"
