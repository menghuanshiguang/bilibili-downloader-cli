#!/usr/bin/env bash
# =====================================================================
# bilibili-preview.sh - 生成B站视频预览页(封面+标题+播放跳转) (Minis)
# 产出 HTML 到 /var/minis/workspace/bilibili-preview/, 返回 minis:// 链接
# 封面可点击跳转 mbplayer 直链播放(移动端 iframe 自动播放被禁, 故用跳转)
#
# 用法:
#   bilibili-preview.sh "<URL|BV号>[?p=N]"
# 示例:
#   bilibili-preview.sh "BV16v411L7js?p=121"
# =====================================================================
set -euo pipefail

INPUT="${1:-}"
[[ -z "$INPUT" ]] && { echo "用法: bilibili-preview.sh \"<URL|BV号>[?p=N]\"" >&2; exit 1; }

HOME_DIR="${HOME:-/root}"
LOGINFILE="$HOME_DIR/.cache/bilibili-login-cookies.txt"
BUFILE="$HOME_DIR/.cache/bilibili-buvid.txt"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
OUTBASE="${PREVIEW_OUT:-/var/minis/workspace/bilibili-preview}"

# ---------- 提取 BV 号和 p 号 ----------
BV="$(echo "$INPUT" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
P_NUM="$(echo "$INPUT" | grep -oE '[?&]p=[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
if [[ -z "$BV" && "$INPUT" =~ b23\.tv ]]; then
    FULL="$(curl -s -o /dev/null --max-redirs 5 -A "$UA" -w "%{url_effective}" -L "$INPUT")"
    BV="$(echo "$FULL" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
    [[ -z "$P_NUM" ]] && P_NUM="$(echo "$FULL" | grep -oE '[?&]p=[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
fi
[[ -z "$BV" ]] && { echo "ERROR: 无法提取 BV 号: $INPUT" >&2; exit 1; }
P_NUM="${P_NUM:-1}"

# ---------- cookies ----------
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

# ---------- 1. view API: 封面 + 标题 ----------
VIEW="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/web-interface/view" \
    --data-urlencode "bvid=$BV" \
    -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$CK" || true)"
read -r PIC TITLE <<< "$(echo "$VIEW" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
data=d.get('data') or {}
pic=(data.get('pic') or '').replace('http://','https://')
print(f\"{pic} {data.get('title','')}\")
" 2>/dev/null || echo "|")"
[[ -z "$PIC" || "$PIC" == "|" ]] && { echo "ERROR: 获取视频信息失败(可能被风控)" >&2; exit 1; }

# ---------- 2. pagelist: 分P列表 ----------
PART_COUNT=1
PARTS_HTML=""
RESP="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/pagelist" \
    --data-urlencode "bvid=$BV" \
    -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$CK" || true)"
read -r PART_COUNT <<< "$(echo "$RESP" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
pages=d.get('data') or []
print(len(pages))
" 2>/dev/null || echo 1)"
if [[ "$PART_COUNT" -gt 1 ]]; then
    PARTS_HTML="$(echo "$RESP" | python3 -c "
import json,sys,html
d=json.load(sys.stdin)
pages=d.get('data') or []
rows=[]
for p in pages:
    dur=p.get('duration',0); m,s=divmod(dur,60)
    rows.append(f\"<div class='part' data-p='{p.get('page')}'><span class='pnum'>P{p.get('page')}</span> <span class='ptitle'>{html.escape(p.get('part',''))}</span> <span class='pdur'>{m}:{s:02d}</span></div>\")
print(''.join(rows))
")"
fi

# ---------- 3. 生成 HTML ----------
mkdir -p "$OUTBASE"
OUTFILE="$OUTBASE/${BV}_p${P_NUM}.html"
PLAYER="https://www.bilibili.com/blackboard/webplayer/mbplayer.html?bvid=${BV}&p=${P_NUM}"
TITLE_ESC="$(echo "$TITLE" | python3 -c "import sys,html;print(html.escape(sys.stdin.read().strip()))" 2>/dev/null || echo "$TITLE")"

cat > "$OUTFILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>${TITLE_ESC}</title>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body { background:#181a20; color:#eee; font-family:-apple-system,"PingFang SC","Noto Sans CJK SC",sans-serif; min-height:100vh; }
.cover-link { display:block; position:relative; width:100%; aspect-ratio:16/9; background:#000; overflow:hidden; text-decoration:none; }
.cover-link img { display:block; width:100%; height:100%; object-fit:cover; opacity:.6; transition:opacity .2s; }
.cover-link:active img { opacity:.9; }
.cover-mask { position:absolute; inset:0; background:linear-gradient(180deg,transparent 30%,rgba(24,26,32,.92) 100%); pointer-events:none; }
.play-btn { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); width:64px; height:64px; border-radius:50%; background:rgba(251,114,153,.92); color:#fff; font-size:26px; display:flex; align-items:center; justify-content:center; box-shadow:0 2px 12px rgba(0,0,0,.4); pointer-events:none; }
.tap-hint { text-align:center; color:#99a2b5; font-size:12px; padding:8px 0 4px; }
.cover-info { position:absolute; left:0; right:0; bottom:0; padding:14px 16px 18px; pointer-events:none; }
.cover-info .badge { display:inline-block; background:#fb7299; color:#fff; font-size:11px; padding:2px 8px; border-radius:10px; margin-bottom:8px; }
.cover-info h1 { font-size:17px; line-height:1.4; font-weight:600; text-shadow:0 1px 3px rgba(0,0,0,.6); }
.section { padding:12px 16px; }
.section h2 { font-size:13px; color:#99a2b5; margin-bottom:8px; font-weight:500; }
.parts { display:flex; flex-direction:column; gap:6px; max-height:280px; overflow-y:auto; -webkit-overflow-scrolling:touch; }
.part { display:flex; align-items:center; gap:10px; padding:8px 10px; background:#23262e; border-radius:8px; font-size:13px; }
.part .pnum { color:#fb7299; font-weight:600; flex-shrink:0; }
.part .ptitle { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.part .pdur { color:#7a8296; flex-shrink:0; font-size:12px; }
.footer { padding:16px; text-align:center; color:#5a6275; font-size:11px; }
</style>
</head>
<body>
<a class="cover-link" href="${PLAYER}">
  <img src="${PIC}" alt="封面" onerror="this.style.display='none'">
  <div class="cover-mask"></div>
  <div class="play-btn">▶</div>
  <div class="cover-info">
    <span class="badge">${PART_COUNT} 个分P${P_NUM:+ · P${P_NUM}}</span>
    <h1>${TITLE_ESC}</h1>
  </div>
</a>
<div class="tap-hint">👆 点击封面播放视频</div>
<div class="section">
  <h2>分P列表</h2>
  <div class="parts">${PARTS_HTML:-<div class="part"><span class="pnum">P1</span><span class="ptitle">单P视频</span></div>}</div>
</div>
<div class="footer">B站预览 · bilibili-downloader-skill</div>
</body>
</html>
HTMLEOF

echo ">>> 预览页已生成: $OUTFILE" >&2
echo ">>> 直链: $PLAYER" >&2
if [[ "$OUTBASE" == /var/minis/* ]]; then
    echo "minis://workspace/bilibili-preview/${BV}_p${P_NUM}.html"
else
    echo "file://$OUTFILE"
fi
