#!/usr/bin/env bash
# =====================================================================
# bilibili-findpart.sh - 在B站多P合集中按关键词定位分P (Minis / iSH)
# 基于官方 API: api.bilibili.com/x/player/pagelist (一次性拉全部分P标题)
#
# ⚠️ 背景坑:
#   - 短链(b23.tv)分享参数自带 p=N, 那是分享时停留位置, 不代表用户要的P
#   - yt-dlp --flat-playlist 打印标题全是 NA, 无法用
#   - 嵌入播放器 player.html?page=N 分P定位有bug(会跳mbplayer显示总时长), 不能验证
#   - ✅ 可靠路径: 本脚本 pagelist API + grep 关键词 → 定位P号 → 用 ?p=N 下载
#
# 用法:
#   bilibili-findpart.sh "<URL|BV号>" "<关键词>"
# 示例:
#   bilibili-findpart.sh "BV16v411L7js" "小草"
#   bilibili-findpart.sh "https://b23.tv/iEGonVr" "九百九十九朵玫瑰"
# =====================================================================
set -euo pipefail

INPUT="${1:-}"
KEYWORD="${2:-}"
[[ -z "$INPUT" || -z "$KEYWORD" ]] && {
    echo "用法: bilibili-findpart.sh \"<URL|BV号>\" \"<关键词>\"" >&2
    exit 1
}

HOME_DIR="${HOME:-/root}"
LOGINFILE="$HOME_DIR/.cache/bilibili-login-cookies.txt"
BUFILE="$HOME_DIR/.cache/bilibili-buvid.txt"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# ---------- 提取 BV 号 (短链也解析) ----------
BV="$(echo "$INPUT" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
if [[ -z "$BV" && "$INPUT" =~ b23\.tv ]]; then
    FULL="$(curl -s -o /dev/null --max-redirs 5 -A "$UA" -w "%{url_effective}" -L "$INPUT")"
    BV="$(echo "$FULL" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
fi
[[ -z "$BV" ]] && { echo "ERROR: 无法从输入提取 BV 号: $INPUT" >&2; exit 1; }

# ---------- cookies: 登录优先, buvid 回落 ----------
CK=""
if [[ -s "$LOGINFILE" ]]; then
    CK="$LOGINFILE"
    echo ">>> 使用登录 cookies" >&2
else
    if [[ ! -s "$BUFILE" ]]; then
        curl -s -c "$BUFILE" -A "$UA" "https://www.bilibili.com/" -o /dev/null
        chmod 600 "$BUFILE" 2>/dev/null || true
    fi
    CK="$BUFILE"
fi

# ---------- 拉取全部分P标题 ----------
echo ">>> 拉取 $BV 全部分P标题..." >&2
RESP="$(curl -sG "https://api.bilibili.com/x/player/pagelist" \
    --data-urlencode "bvid=$BV" \
    -H "User-Agent: $UA" \
    -H "Referer: https://www.bilibili.com/" \
    -b "$CK" || true)"

echo "$RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('ERROR: 返回非JSON(可能被风控), 先运行 bilibili-login.sh 登录再试', file=sys.stderr)
    sys.exit(2)
if d.get('code') != 0:
    print(f\"API错误 code={d.get('code')} message={d.get('message')}\", file=sys.stderr)
    sys.exit(1)
pages = d.get('data') or []
kw = '$KEYWORD'
print(f'分P总数: {len(pages)}', file=sys.stderr)

hits = []
for p in pages:
    title = p.get('part', '')
    if kw.lower() in title.lower():
        hits.append((p.get('page'), title))

if hits:
    print(f'★ 关键词「{kw}」匹配 {len(hits)} 个分P:')
    for page, title in hits:
        print(f'  P{page}: {title}')
    print()
    print('下载命令示例:')
    for page, _ in hits[:3]:
        print(f'  bilibili-dl.sh \"$BV\" video ... mp4 1080 {page}')
else:
    print(f'未找到包含「{kw}」的分P。可尝试其他关键词(歌名/演唱者)。')
"
