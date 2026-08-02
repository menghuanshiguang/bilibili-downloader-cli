#!/usr/bin/env bash
# =====================================================================
# bilibili-parts.sh - 查询B站视频分P信息 (Minis / iSH - Alpine Linux)
# 基于官方 API: api.bilibili.com/x/player/pagelist (一次性拉全部分P, 秒出)
#
# ⚠️ 为什么不用 yt-dlp: 非flat模式会逐个解析全部分P, 561P合集要几分钟(卡死);
#   flat模式标题全NA。pagelist API 一次请求返回全部, 无论多少P都秒出。
#
# 用法:
#   bilibili-parts.sh "<URL|BV号>"
# 示例:
#   bilibili-parts.sh "BV1GV4y1W7vh"
#   bilibili-parts.sh "BV16v411L7js?p=353"
# =====================================================================
set -euo pipefail

INPUT="${1:-}"
[[ -z "$INPUT" ]] && { echo "用法: bilibili-parts.sh \"<URL|BV号>\"" >&2; exit 1; }

HOME_DIR="${HOME:-/root}"
LOGINFILE="$HOME_DIR/.cache/bilibili-login-cookies.txt"
BUFILE="$HOME_DIR/.cache/bilibili-buvid.txt"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# ---------- 提取 BV 号 (支持 BVxxx / BVxxx?p=N / 完整URL / b23短链) ----------
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
else
    if [[ ! -s "$BUFILE" ]]; then
        curl -s -c "$BUFILE" -A "$UA" "https://www.bilibili.com/" -o /dev/null
        chmod 600 "$BUFILE" 2>/dev/null || true
    fi
    CK="$BUFILE"
fi

# ---------- 拉取全部分P (一次请求, 秒出) ----------
echo ">>> 查询分P: $BV" >&2
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
if not pages:
    print('单P视频(无分P)')
    sys.exit(0)
print(f'分P数: {len(pages)}')
for p in pages:
    dur = p.get('duration', 0)
    m, s = divmod(dur, 60)
    print(f\"P{p.get('page')} [{m}:{s:02d}] {p.get('part','')}  (cid={p.get('cid','')})\")
print('END')
"
