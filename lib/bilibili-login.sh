#!/usr/bin/env bash
# =====================================================================
# bilibili-login.sh - B站扫码登录脚本 (Minis / iSH)
# 获取登录 cookies (SESSDATA 等), 保存到文件供 bilibili-dl.sh 使用
#
# 用法:
#   bilibili-login.sh [cookies文件路径]
#   默认 cookies 保存到 ~/.cache/bilibili-login-cookies.txt
#
# 流程:
#   1. 调 B站 passport API 获取二维码 qrcode_key
#   2. 生成二维码 HTML 页面, 用浏览器打开
#   3. 用户用 B站 App 扫码确认
#   4. 轮询登录状态, 成功后保存 cookies
# =====================================================================
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
HOME_DIR="${HOME:-/root}"
COOKIE_FILE="${1:-${HOME_DIR}/.cache/bilibili-login-cookies.txt}"
QR_HTML="${HOME_DIR}/bilibili-login-qr.html"
mkdir -p "$(dirname "$COOKIE_FILE")"

echo "=============================================="
echo " B站扫码登录"
echo " cookies 保存到: $COOKIE_FILE"
echo "=============================================="

# ---------- 1. 获取二维码 qrcode_key ----------
echo ">>> 获取登录二维码..."
GEN=$(curl -s "https://passport.bilibili.com/x/passport-login/web/qrcode/generate" \
    -A "$UA" -e "https://www.bilibili.com/" -H "Referer:https://www.bilibili.com/")

QRC_KEY=$(echo "$GEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['qrcode_key'])" 2>/dev/null)
QR_URL=$(echo "$GEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['url'])" 2>/dev/null)
[[ -z "$QRC_KEY" ]] && { echo "❌ 获取二维码失败"; exit 1; }

# ---------- 2. 生成二维码 HTML (用官方 data.url, 确保扫码可识别) ----------
echo ">>> 生成二维码页面: $QR_HTML"

python3 - "$QR_URL" "$QR_HTML" <<'EOF'
import qrcode, io, base64, sys
url = sys.argv[1]   # 官方 data.url, 保证扫码可识别
img = qrcode.make(url)
buf = io.BytesIO()
img.save(buf, format='PNG')
b64 = base64.b64encode(buf.getvalue()).decode()
html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>B站扫码登录</title>
<style>
body{{font-family:sans-serif;text-align:center;background:#f5f5f5;padding:20px}}
.card{{background:#fff;max-width:420px;margin:40px auto;padding:30px;border-radius:16px;box-shadow:0 2px 12px rgba(0,0,0,.1)}}
h2{{color:#fb7299}} p{{color:#666}}
img{{width:300px;height:300px;border:1px solid #eee;border-radius:10px}}
.tip{{font-size:13px;color:#999;margin-top:10px}}
code{{background:#f0f0f0;padding:2px 6px;border-radius:4px}}
</style></head>
<body><div class="card">
<h2>B站扫码登录</h2>
<p>用 <b>B站 App</b> 扫一扫，确认登录</p>
<img src="data:image/png;base64,{b64}"/>
<p class="tip">登录成功后 cookies 将保存到<br/><code>~/.cache/bilibili-login-cookies.txt</code></p>
<p class="tip">如二维码失效，重新运行 <code>bilibili-login.sh</code></p>
</div></body></html>"""
open(sys.argv[2], 'w').write(html)
print("HTML 生成完成")
EOF

echo ">>> 请打开二维码页面扫码:"
echo "    终端: 打开 $QR_HTML"
echo "    应用内: 用浏览器打开下面HTML文件"
[ -f "$QR_HTML" ] && echo "    ✅ 二维码页面已生成: $QR_HTML"

# ---------- 3. 轮询登录状态 (用 GET 请求, B站 poll 不接受 POST) ----------
echo ""
echo ">>> 等待扫码确认 (最长120秒)..."
POLL_URL="https://passport.bilibili.com/x/passport-login/web/qrcode/poll"
CODE="-1"
CROSS_URL=""
TICKET=""
: > /tmp/bb_login_ck.txt
for i in $(seq 1 24); do
    sleep 5
    # 重要: GET 请求 (curl -G), 不要用 POST
    RES=$(curl -s -G \
        -c /tmp/bb_login_ck.txt -b /tmp/bb_login_ck.txt \
        -H "User-Agent: $UA" \
        -H "Referer: https://www.bilibili.com/" \
        -H "Origin: https://www.bilibili.com" \
        --data-urlencode "qrcode_key=$QRC_KEY" \
        "$POLL_URL")
    
    CODE=$(echo "$RES" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'].get('code'))" 2>/dev/null || echo "-1")
    case "$CODE" in
        0)   echo ">>> ✅ 扫码确认！正在获取登录态..."; break ;;
        86038) echo ">>> 二维码已失效，请重新运行登录脚本" >&2; exit 1 ;;
        86090) echo ">>> 已扫码，等待确认...($i) 请在手机上点确认"; continue ;;
        *)   echo ">>> 等待扫码...($i)" ;;
    esac
done

# ---------- 4. 通过 crossDomain 获取 SESSDATA 并保存 cookies ----------
if [[ "$CODE" == "0" ]]; then
    echo ">>> 完成扫码确认，跳转兑换 cookies..."
    CROSS_URL=$(echo "$RES" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d['data'].get('url',''))
except: print('')")
    if [[ -n "$CROSS_URL" ]]; then
        echo ">>> 访问 crossDomain 获取 SESSDATA..."
        curl -s -L -o /dev/null \
            -c /tmp/bb_login_ck.txt -b /tmp/bb_login_ck.txt \
            -H "User-Agent: $UA" \
            -H "Referer: https://www.bilibili.com/" \
            "$CROSS_URL"
    fi
    if grep -q "SESSDATA" /tmp/bb_login_ck.txt 2>/dev/null; then
        cp /tmp/bb_login_ck.txt "$COOKIE_FILE"
        chmod 600 "$COOKIE_FILE"
        echo ""
        echo "✅ 登录成功！cookies 已保存: $COOKIE_FILE"
        echo "  现在可用 bilibili-dl.sh 下载高清 (720P+/1080P)"
    else
        echo "❌ 未获取到 SESSDATA cookie" >&2
        cat /tmp/bb_login_ck.txt 2>&1
        exit 1
    fi
else
    echo "❌ 登录超时或失败" >&2; exit 1
fi
