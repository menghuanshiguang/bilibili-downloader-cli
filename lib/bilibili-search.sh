#!/usr/bin/env bash
# =====================================================================
# bilibili-search.sh - B站视频搜索 (Minis / iSH - Alpine Linux)
# 内置 WAF 风控规避: 搜索 API 必须携带 cookies(登录或 buvid), 否则返回风控页
#
# 用法:
#   bilibili-search.sh "<关键词>" [条数]
# 示例:
#   bilibili-search.sh "卓依婷 萍聚"
#   bilibili-search.sh "Beyond 岁月无声" 5
# =====================================================================
set -euo pipefail

KEYWORD="${1:-}"
COUNT="${2:-10}"
[[ -z "$KEYWORD" ]] && { echo "用法: bilibili-search.sh \"<关键词>\" [条数]" >&2; exit 1; }

HOME_DIR="${HOME:-/root}"
LOGINFILE="$HOME_DIR/.cache/bilibili-login-cookies.txt"
BUFILE="$HOME_DIR/.cache/bilibili-buvid.txt"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# ---------- cookies 准备: 登录优先, 回落 buvid ----------
CK=""
if [[ -s "$LOGINFILE" ]]; then
    CK="$LOGINFILE"
    echo ">>> 使用登录 cookies" >&2
elif [[ -s "$BUFILE" ]]; then
    CK="$BUFILE"
    echo ">>> 使用 buvid cookies (游客)" >&2
else
    echo ">>> 获取 buvid cookie..." >&2
    curl -s -c "$BUFILE" -A "$UA" "https://www.bilibili.com/" -o /dev/null
    chmod 600 "$BUFILE" 2>/dev/null || true
    CK="$BUFILE"
fi

# ---------- 搜索 ----------
echo ">>> 搜索: $KEYWORD" >&2
RESP="$(curl -sG "https://api.bilibili.com/x/web-interface/search/type" \
    --data-urlencode "search_type=video" \
    --data-urlencode "keyword=$KEYWORD" \
    --data-urlencode "page=1" \
    -H "User-Agent: $UA" \
    -H "Referer: https://www.bilibili.com/" \
    -H "Origin: https://search.bilibili.com" \
    -b "$CK")"

echo "$RESP" | python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('解析失败: 返回非JSON, 可能被风控拦截 (', e, ')', file=sys.stderr)
    sys.exit(2)
if d.get('code') != 0:
    print(f\"API错误 code={d.get('code')} message={d.get('message')}\", file=sys.stderr)
    sys.exit(1)
res = d.get('data', {}).get('result') or []
count = int('$COUNT')
for i, v in enumerate(res[:count]):
    title = re.sub(r'</?em[^>]*>', '', v.get('title', ''))
    dur = v.get('duration', '?')
    bvid = v.get('bvid', '?')
    author = v.get('author', '?')
    play = v.get('play', '?')
    print(f\"{i+1}. [{dur}] {title}\")
    print(f\"   BV: {bvid} | UP: {author} | 播放: {play}\")
print(f\"共 {len(res[:count])} 条 (总结果 {d.get('data',{}).get('numResults','?')})\", file=sys.stderr)
"
