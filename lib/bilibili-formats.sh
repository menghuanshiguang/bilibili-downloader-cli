#!/usr/bin/env bash
# =====================================================================
# bilibili-formats.sh - 查询B站视频可用格式 (Minis / iSH - Alpine Linux)
# 纯官方API方案(秒出), 不经过 yt-dlp:
#   1. pagelist API → 拿到指定P(或第1P)的 cid
#   2. playurl API  → 拿到该cid的可用画质/编码/分辨率
#
# ⚠️ 为什么不用 yt-dlp -F: 对多P合集(如561P)会遍历播放列表, 卡死几分钟
# ⚠️ 反爬: 全程带登录/buvid cookies + UA + Referer, 裸调必 412
#
# 用法:
#   bilibili-formats.sh "<URL|BV号>[?p=N]"
# 示例:
#   bilibili-formats.sh "BV1QJ4m1j7oz"
#   bilibili-formats.sh "BV16v411L7js?p=121"   # 查询合集第121P
# =====================================================================
set -euo pipefail

INPUT="${1:-}"
[[ -z "$INPUT" ]] && { echo "用法: bilibili-formats.sh \"<URL|BV号>[?p=N]\"" >&2; exit 1; }

HOME_DIR="${HOME:-/root}"
LOGINFILE="$HOME_DIR/.cache/bilibili-login-cookies.txt"
BUFILE="$HOME_DIR/.cache/bilibili-buvid.txt"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# ---------- 提取 BV 号和 p 号 ----------
BV="$(echo "$INPUT" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
P_NUM="$(echo "$INPUT" | grep -oE '[?&]p=[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
if [[ -z "$BV" && "$INPUT" =~ b23\.tv ]]; then
    FULL="$(curl -s -o /dev/null --max-redirs 5 -A "$UA" -w "%{url_effective}" -L "$INPUT")"
    BV="$(echo "$FULL" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
    [[ -z "$P_NUM" ]] && P_NUM="$(echo "$FULL" | grep -oE '[?&]p=[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
fi
[[ -z "$BV" ]] && { echo "ERROR: 无法从输入提取 BV 号: $INPUT" >&2; exit 1; }
P_NUM="${P_NUM:-1}"

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

# ---------- 1. pagelist: 拿 cid ----------
echo ">>> 查询格式: $BV p=$P_NUM" >&2
RESP="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/pagelist" \
    --data-urlencode "bvid=$BV" \
    -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$CK" || true)"

CID="$(echo "$RESP" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception:
    print('ERROR: pagelist返回非JSON(可能被风控), 先运行 bilibili-login.sh 登录再试', file=sys.stderr); sys.exit(2)
if d.get('code')!=0:
    print(f\"API错误 code={d.get('code')} {d.get('message')}\", file=sys.stderr); sys.exit(1)
pages=d.get('data') or []
target=[p for p in pages if p.get('page')==int('$P_NUM')]
if not target:
    print(f\"未找到 P$P_NUM (共{len(pages)}P)\", file=sys.stderr); sys.exit(1)
print(target[0]['cid'])
" 2>/dev/null)" || { echo "$RESP" >&2; exit 1; }

# ---------- 2. playurl: 拿格式 ----------
PU="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/playurl" \
    --data-urlencode "bvid=$BV" \
    --data-urlencode "cid=$CID" \
    --data-urlencode "qn=80" \
    --data-urlencode "fnval=16" \
    --data-urlencode "fourk=1" \
    -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$CK" || true)"

echo "$PU" | python3 -c "
import json, sys
try: d = json.load(sys.stdin)
except Exception:
    print('ERROR: playurl返回非JSON(可能被风控)', file=sys.stderr); sys.exit(2)
if d.get('code') != 0:
    print(f\"API错误 code={d.get('code')} {d.get('message')}\", file=sys.stderr); sys.exit(1)
data = d.get('data') or {}
qn_map = {16:'360p',32:'480p',64:'720p',80:'1080p',112:'1080p高码',116:'1080p60',120:'4K'}

# 收集视频流 (dash 或 durl)
streams = []
dash = data.get('dash') or {}
for v in dash.get('video') or []:
    streams.append((v.get('id'), v.get('codecs','?'), f\"{v.get('width')}x{v.get('height')}\"))
for durl in data.get('durl') or []:
    qn = data.get('quality', 0)
    streams.append((qn, 'durl', f'?x? qn={qn}'))

if not streams:
    print('无视频流(可能需登录或付费)')
    sys.exit(0)

# 去重排序
seen=set(); uniq=[]
for s in streams:
    if s[0] not in seen:
        seen.add(s[0]); uniq.append(s)
uniq.sort(key=lambda x: -(x[0] or 0))

print('=== 视频格式 ===')
for qn, codec, res in uniq:
    mark = ' ← H.264' if str(codec).startswith('avc') else (' ← HEVC' if str(codec).startswith(('hev','hvc')) else '')
    label = qn_map.get(qn, f'qn={qn}')
    print(f'  {label:<10} {res:<12} {codec}{mark}')

max_qn = uniq[0][0]
max_label = qn_map.get(max_qn, f'qn={max_qn}')
h264 = [s for s in uniq if str(s[1]).startswith('avc')]
h264_max = qn_map.get(h264[0][0], f'qn={h264[0][0]}') if h264 else '无'
print()
print(f'最高分辨率: {max_label}')
print(f'H.264最高: {h264_max}' + ('  (下载可免转码)' if h264 else '  (无H.264, 需转码)'))
print(f'音频: {len(dash.get(\"audio\") or [])} 条')
"
