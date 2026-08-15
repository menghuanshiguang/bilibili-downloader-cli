#!/usr/bin/env bash
# =====================================================================
# bilibili-space.sh - 获取UP主主页视频列表 (Minis / iSH - Alpine Linux)
# 内置 wbi 签名 + cookies(buvid/登录), 绕过风控
#
# 用法:
#   bilibili-space.sh "<UID|空间URL|b23短链>" [条数]
# 示例:
#   bilibili-space.sh "2137589551"
#   bilibili-space.sh "https://space.bilibili.com/2137589551" 20
#   bilibili-space.sh "https://b23.tv/xxx" 10
# =====================================================================
set -euo pipefail
# Windows(Git Bash) 适配: python3 缺失时自动回退 python
PYBIN="$(command -v python3 || command -v python || true)"
PYBIN="${PYBIN:-python3}"


INPUT="${1:-}"
COUNT="${2:-10}"
[[ -z "$INPUT" ]] && { echo "用法: bilibili-space.sh \"<UID|空间URL>\" [条数]" >&2; exit 1; }

HOME_DIR="${HOME:-/root}"
LOGINFILE="$HOME_DIR/.cache/bilibili-login-cookies.txt"
BUFILE="$HOME_DIR/.cache/bilibili-buvid.txt"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# ---------- cookies 准备 ----------
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

# ---------- 解析 UID ----------
UID_ARG="$(echo "$INPUT" | sed -E 's|.*space\.bilibili\.com/([0-9]+).*|\1|')"
if [[ "$UID_ARG" == "$INPUT" ]] && [[ "$INPUT" != *[0-9]* ]]; then
    echo ">>> 解析短链..." >&2
    FINAL="$(curl -sL -o /dev/null -w "%{url_effective}" -A "$UA" "$INPUT")"
    UID_ARG="$(echo "$FINAL" | sed -E 's|.*space\.bilibili\.com/([0-9]+).*|\1|')"
fi
if ! [[ "$UID_ARG" =~ ^[0-9]+$ ]]; then
    echo "无法解析UID: $INPUT" >&2
    exit 1
fi
echo ">>> UID: $UID_ARG" >&2

# ---------- wbi 签名 + 拉取列表 ----------
"$PYBIN" - "$UID_ARG" "$COUNT" "$CK" << 'PYEOF'
import sys, urllib.request, urllib.parse, json, hashlib, time, os

uid, count, ckfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120"

# 解析Netscape格式cookie文件 → "k=v; k2=v2"
def load_cookies(path):
    if not path or not os.path.exists(path):
        return ""
    pairs = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 7:
            pairs.append(f"{parts[5]}={parts[6]}")
    return "; ".join(pairs)

ck = load_cookies(ckfile)

def api(url, referer=None):
    h = {"User-Agent": UA, "Cookie": ck}
    if referer: h["Referer"] = referer
    req = urllib.request.Request(url, headers=h)
    return json.loads(urllib.request.urlopen(req, timeout=15).read().decode())

# wbi key
try:
    d = api("https://api.bilibili.com/x/web-interface/nav")
    img = d["data"]["wbi_img"]["img_url"].split("/")[-1].split(".")[0]
    sub = d["data"]["wbi_img"]["sub_url"].split("/")[-1].split(".")[0]
    key = img + sub
except Exception as e:
    print(f"wbi key获取失败: {e}", file=sys.stderr); sys.exit(2)

MIXIN = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
mixin_key = ''.join(key[i] for i in MIXIN)[:32]

# 多页拉取直到够 count
vlist_all = []
page = 1
total = None
while len(vlist_all) < count and page <= 20:
    params = {"mid": uid, "ps": "20", "pn": str(page), "order": "pubdate", "wts": int(time.time())}
    items = sorted(params.items())
    query = urllib.parse.urlencode(items)
    params["w_rid"] = hashlib.md5((query + mixin_key).encode()).hexdigest()
    url = "https://api.bilibili.com/x/space/wbi/arc/search?" + urllib.parse.urlencode(params)
    d2 = api(url, referer=f"https://space.bilibili.com/{uid}")
    if d2.get("code") != 0:
        print(f"API错误 code={d2.get('code')} {d2.get('message','')}", file=sys.stderr)
        break
    if total is None:
        total = d2["data"]["page"]["count"]
    vlist = d2["data"]["list"]["vlist"]
    if not vlist: break
    vlist_all.extend(vlist)
    page += 1

if total is not None:
    print(f"UP主视频总数: {total}, 列出 {min(count, len(vlist_all))} 条:", file=sys.stderr)
for i, v in enumerate(vlist_all[:count], 1):
    print(f"{i}. [{v['length']}] {v['title']}")
    print(f"   BV: {v['bvid']} | UP: {v.get('author','')} | 播放: {v['play']} | 评论: {v.get('comment',0)}")
PYEOF
