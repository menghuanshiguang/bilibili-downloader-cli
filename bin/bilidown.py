#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =====================================================================
# bilidown - B站音视频下载 CLI (跨平台 Python 单文件版)
#
# 基于官方 API 直链 + yt-dlp, 内置 HTTP 412 反爬规避(buvid/登录 cookies +
# UA + Referer/Origin + player_client=web) + 扫码登录解锁高清 + AV1 自动规避
# (H.264 优先) + 合集秒下(561P 不卡) + 片段截取。
#
# 跨平台: Windows / macOS / Linux / iSH / Termux 只需 Python 3.8+,
# 不再依赖 bash / curl / msys 路径转换。
#
# 依赖:
#   ffmpeg/ffprobe  - 音频 remux / 视频合并转码 (必需, 缺失时给出安装指引)
#   yt-dlp          - 仅 list(批量 UP 主空间)模式
#   qrcode          - 仅 login 扫码登录的二维码图片(缺失时降级为链接页)
#
# 用法:
#   bilidown dl <URL|BV号> [audio|video|list] [输出目录] [容器mp4|mkv] [分辨率480|720|1080] [分P号] [截取区间]
#   bilidown search <关键词> [条数]
#   bilidown login [cookies路径]
#   bilidown formats <URL|BV号>
#   bilidown parts <URL|BV号>
#   bilidown find <URL|BV号> <关键词>
#   bilidown preview <URL|BV号>
#   bilidown space <UID|空间URL> [条数]
# =====================================================================
import base64
import hashlib
import html
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

VERSION = "2.0.0"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
HOME_DIR = os.path.expanduser("~")
CACHE_DIR = os.path.join(HOME_DIR, ".cache")
LOGINFILE = os.path.join(CACHE_DIR, "bilibili-login-cookies.txt")
BUFILE = os.path.join(CACHE_DIR, "bilibili-buvid.txt")
WORK = os.path.join(HOME_DIR, "B站音频下载")
OUTBASE = os.environ.get("PREVIEW_OUT", os.path.join(os.getcwd(), "bilibili-preview"))


# =====================================================================
# 工具函数
# =====================================================================

def log(msg):
    print(msg, file=sys.stderr)


def safe_name(s):
    for ch in '/\\:*?"<>|':
        s = s.replace(ch, "")
    return s


def extract_bv(text):
    m = re.search(r"BV[0-9A-Za-z]{10}", text or "")
    return m.group(0) if m else ""


def extract_p(text):
    m = re.search(r"[?&]p=(\d+)", text or "")
    return m.group(1) if m else ""


def normalize_input(text):
    """归一化输入: BV号 / BV?p=N / 完整URL / b23.tv 短链 / 纯 UID。返回 (bv, p, url)。"""
    bv = extract_bv(text)
    p = extract_p(text)
    if not bv and "b23.tv" in text:
        try:
            req = urllib.request.Request(text, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=15) as resp:
                final = resp.geturl()
            bv = extract_bv(final)
            if not p:
                p = extract_p(final)
        except Exception:
            pass
    return bv, p, text


# =====================================================================
# cookies 管理 (Netscape 格式, 与 yt-dlp 兼容)
# =====================================================================

def parse_netscape(path):
    """Netscape cookie 文件 → "k=v; k2=v2" 字符串"""
    pairs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 7:
                    pairs.append(f"{parts[5]}={parts[6]}")
    except OSError:
        pass
    return "; ".join(pairs)


def write_netscape(path, jar):
    """http.cookiejar → Netscape 格式文件"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("# Netscape HTTP Cookie File\n")
        for c in jar:
            f.write("\t".join([
                c.domain, "TRUE" if c.domain.startswith(".") else "FALSE",
                c.path, "TRUE" if c.secure else "FALSE",
                str(int(c.expires)) if c.expires else "0",
                c.name, c.value,
            ]) + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def get_cookies(verbose=True):
    """登录 cookies 优先, buvid 兜底。返回 cookie 字符串。"""
    if os.path.isfile(LOGINFILE) and os.path.getsize(LOGINFILE) > 0:
        if verbose:
            log(">>> 使用登录 cookies (高清可用)")
        return parse_netscape(LOGINFILE)
    if not (os.path.isfile(BUFILE) and os.path.getsize(BUFILE) > 0):
        if verbose:
            log(">>> 获取 buvid cookie...")
        _fetch_buvid()
    return parse_netscape(BUFILE)


def _fetch_buvid():
    os.makedirs(CACHE_DIR, exist_ok=True)
    import http.cookiejar
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request("https://www.bilibili.com/", headers={"User-Agent": UA})
    try:
        with opener.open(req, timeout=15):
            pass
    except Exception:
        pass
    write_netscape(BUFILE, jar)


# =====================================================================
# HTTP
# =====================================================================

def http_get(url, params=None, referer="https://www.bilibili.com/", origin=None,
             cookies=None, timeout=20, follow=True):
    if params:
        sep = "&" if "?" in url else "?"
        url = url + sep + urllib.parse.urlencode(params)
    headers = {
        "User-Agent": UA,
        "Referer": referer or "https://www.bilibili.com/",
        "Accept": "application/json, text/plain, */*",
    }
    if origin:
        headers["Origin"] = origin
    if cookies:
        headers["Cookie"] = cookies
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def http_get_json(url, params=None, referer="https://www.bilibili.com/", origin=None,
                  cookies=None, timeout=20):
    try:
        raw = http_get(url, params, referer, origin, cookies, timeout)
    except urllib.error.HTTPError as e:
        if e.code == 412:
            sys.exit("ERROR: HTTP 412 被风控拦截。请先运行 `bilidown login` 扫码登录后重试, 或稍后再试。")
        raise
    try:
        return json.loads(raw)
    except Exception:
        sys.exit("ERROR: 返回非 JSON, 可能被风控拦截。请先运行 `bilidown login` 登录, 或稍后再试。")


def download_to(url, dest, referer="https://www.bilibili.com/", timeout=600):
    """流式下载到文件, 返回字节数。"""
    headers = {"User-Agent": UA, "Referer": referer}
    req = urllib.request.Request(url, headers=headers)
    total = 0
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(dest, "wb") as f:
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            f.write(chunk)
            total += len(chunk)
    return total


# =====================================================================
# ffmpeg / ffprobe
# =====================================================================

def find_tool(name):
    return shutil.which(name)


def check_ffmpeg():
    ffmpeg = find_tool("ffmpeg")
    ffprobe = find_tool("ffprobe")
    if not ffmpeg or not ffprobe:
        sys.exit(
            "ERROR: 未找到 ffmpeg/ffprobe, 本命令需要它们。请先安装:\n"
            "  Windows: winget install Gyan.FFmpeg   或   pip install static-ffmpeg\n"
            "  macOS  : brew install ffmpeg\n"
            "  Linux  : apt install ffmpeg 或 apk add ffmpeg"
        )
    return ffmpeg, ffprobe


def ffprobe_field(ffprobe, path, stream, field):
    try:
        out = subprocess.run(
            [ffprobe, "-v", "error", "-select_streams", stream,
             "-show_entries", f"stream={field}",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=60,
        ).stdout.strip()
        return out.splitlines()[0] if out else ""
    except Exception:
        return ""


# =====================================================================
# API 层
# =====================================================================

def api_pagelist(bv, cookies):
    return http_get_json("https://api.bilibili.com/x/player/pagelist",
                         {"bvid": bv}, cookies=cookies)


def api_playurl(bv, cid, qn=80, cookies=None):
    return http_get_json("https://api.bilibili.com/x/player/playurl",
                         {"bvid": bv, "cid": cid, "qn": qn, "fnval": 16, "fourk": 1},
                         cookies=cookies)


def get_page_info(bv, pnum, cookies):
    """返回 (cid, title)。"""
    d = api_pagelist(bv, cookies)
    if d.get("code") != 0:
        sys.exit(f"ERROR: API错误 code={d.get('code')} {d.get('message')}")
    pages = d.get("data") or []
    target = [p for p in pages if p.get("page") == pnum]
    if not target:
        sys.exit(f"ERROR: 获取 cid 失败(风控或 P{pnum} 不存在)")
    return target[0].get("cid", ""), target[0].get("part", f"P{pnum}")


# =====================================================================
# 子命令: parts / find / formats
# =====================================================================

def cmd_parts(text):
    bv, _, _ = normalize_input(text)
    if not bv:
        sys.exit(f"ERROR: 无法从输入提取 BV 号: {text}")
    log(f">>> 查询分P: {bv}")
    ck = get_cookies(verbose=False)
    d = api_pagelist(bv, ck)
    if d.get("code") != 0:
        sys.exit(f"API错误 code={d.get('code')} {d.get('message')}")
    pages = d.get("data") or []
    if not pages:
        print("单P视频(无分P)")
        return
    print(f"分P数: {len(pages)}")
    for p in pages:
        dur = p.get("duration", 0)
        m, s = divmod(dur, 60)
        print(f"P{p.get('page')} [{m}:{s:02d}] {p.get('part','')}  (cid={p.get('cid','')})")
    print("END")


def cmd_find(text, keyword):
    bv, _, _ = normalize_input(text)
    if not bv:
        sys.exit(f"ERROR: 无法从输入提取 BV 号: {text}")
    log(f">>> 拉取 {bv} 全部分P标题...")
    ck = get_cookies(verbose=False)
    d = api_pagelist(bv, ck)
    if d.get("code") != 0:
        sys.exit(f"API错误 code={d.get('code')} {d.get('message')}")
    pages = d.get("data") or []
    log(f"分P总数: {len(pages)}")
    kw = keyword.lower()
    hits = [(p.get("page"), p.get("part", "")) for p in pages if kw in p.get("part", "").lower()]
    if hits:
        print(f"★ 关键词「{keyword}」匹配 {len(hits)} 个分P:")
        for page, title in hits:
            print(f"  P{page}: {title}")
        print()
        print("下载命令示例:")
        for page, _ in hits[:3]:
            print(f"  bilidown dl \"{bv}\" video ... mp4 1080 {page}")
    else:
        print(f"未找到包含「{keyword}」的分P。可尝试其他关键词(歌名/演唱者)。")


def cmd_formats(text):
    bv, pnum, _ = normalize_input(text)
    if not bv:
        sys.exit(f"ERROR: 无法从输入提取 BV 号: {text}")
    pnum = int(pnum or 1)
    log(f">>> 查询格式: {bv} p={pnum}")
    ck = get_cookies()
    cid, _ = get_page_info(bv, pnum, ck)
    d = api_playurl(bv, cid, qn=80, cookies=ck)
    if d.get("code") != 0:
        sys.exit(f"API错误 code={d.get('code')} {d.get('message')}")
    data = d.get("data") or {}
    qn_map = {16: '360p', 32: '480p', 64: '720p', 80: '1080p', 112: '1080p高码',
              116: '1080p60', 120: '4K'}

    streams = []
    dash = data.get("dash") or {}
    for v in dash.get("video") or []:
        streams.append((v.get("id"), v.get("codecs", "?"), f"{v.get('width')}x{v.get('height')}"))
    for _ in data.get("durl") or []:
        streams.append((data.get("quality", 0), "durl", f"?x? qn={data.get('quality', 0)}"))

    if not streams:
        print("无视频流(可能需登录或付费)")
        return

    seen, uniq = set(), []
    for s in streams:
        if s[0] not in seen:
            seen.add(s[0])
            uniq.append(s)
    uniq.sort(key=lambda x: -(x[0] or 0))

    print("=== 视频格式 ===")
    for qn, codec, res in uniq:
        mark = (" ← H.264" if str(codec).startswith("avc")
                else (" ← HEVC" if str(codec).startswith(("hev", "hvc")) else ""))
        label = qn_map.get(qn, f"qn={qn}")
        print(f"  {label:<10} {res:<12} {codec}{mark}")

    max_qn = uniq[0][0]
    max_label = qn_map.get(max_qn, f"qn={max_qn}")
    h264 = [s for s in uniq if str(s[1]).startswith("avc")]
    h264_max = qn_map.get(h264[0][0], f"qn={h264[0][0]}") if h264 else "无"
    print()
    print(f"最高分辨率: {max_label}")
    print(f"H.264最高: {h264_max}" + ("  (下载可免转码)" if h264 else "  (无H.264, 需转码)"))
    print(f"音频: {len(dash.get('audio') or [])} 条")


# =====================================================================
# 子命令: search
# =====================================================================

def cmd_search(keyword, count=10):
    if not keyword:
        sys.exit('用法: bilidown search "<关键词>" [条数]')
    ck = get_cookies()
    log(f">>> 搜索: {keyword}")
    d = http_get_json(
        "https://api.bilibili.com/x/web-interface/search/type",
        {"search_type": "video", "keyword": keyword, "page": 1},
        referer="https://www.bilibili.com/", origin="https://search.bilibili.com",
        cookies=ck,
    )
    if d.get("code") != 0:
        sys.exit(f"API错误 code={d.get('code')} {d.get('message')}")
    res = (d.get("data") or {}).get("result") or []
    for i, v in enumerate(res[:count], 1):
        title = re.sub(r"</?em[^>]*>", "", v.get("title", ""))
        print(f"{i}. [{v.get('duration', '?')}] {title}")
        print(f"   BV: {v.get('bvid', '?')} | UP: {v.get('author', '?')} | 播放: {v.get('play', '?')}")
    log(f"共 {len(res[:count])} 条 (总结果 {(d.get('data') or {}).get('numResults', '?')})")


# =====================================================================
# 子命令: space (wbi 签名)
# =====================================================================

MIXIN = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
         49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
         40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
         62, 11, 36, 20, 34, 44, 52]


def cmd_space(text, count=10):
    if not text:
        sys.exit('用法: bilidown space "<UID|空间URL>" [条数]')
    ck = get_cookies()
    m = re.search(r"space\.bilibili\.com/(\d+)", text)
    if m:
        uid = m.group(1)
    elif re.fullmatch(r"\d+", text):
        uid = text
    else:
        log(">>> 解析短链...")
        try:
            req = urllib.request.Request(text, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=15) as resp:
                final = resp.geturl()
            m = re.search(r"space\.bilibili\.com/(\d+)", final)
            uid = m.group(1) if m else ""
        except Exception:
            uid = ""
    if not re.fullmatch(r"\d+", uid or ""):
        sys.exit(f"无法解析UID: {text}")
    log(f">>> UID: {uid}")

    d = http_get_json("https://api.bilibili.com/x/web-interface/nav", cookies=ck)
    try:
        img = d["data"]["wbi_img"]["img_url"].split("/")[-1].split(".")[0]
        sub = d["data"]["wbi_img"]["sub_url"].split("/")[-1].split(".")[0]
    except Exception:
        sys.exit("ERROR: wbi key 获取失败(可能被风控), 请稍后重试或先登录")

    mixin_key = "".join((img + sub)[i] for i in MIXIN)[:32]

    vlist_all = []
    page = 1
    total = None
    while len(vlist_all) < count and page <= 20:
        params = {"mid": uid, "ps": "20", "pn": str(page), "order": "pubdate", "wts": int(time.time())}
        query = urllib.parse.urlencode(sorted(params.items()))
        params["w_rid"] = hashlib.md5((query + mixin_key).encode()).hexdigest()
        d2 = http_get_json("https://api.bilibili.com/x/space/wbi/arc/search",
                           params, referer=f"https://space.bilibili.com/{uid}", cookies=ck)
        if d2.get("code") != 0:
            log(f"API错误 code={d2.get('code')} {d2.get('message','')}")
            break
        if total is None:
            total = (d2.get("data") or {}).get("page", {}).get("count")
        vlist = ((d2.get("data") or {}).get("list") or {}).get("vlist") or []
        if not vlist:
            break
        vlist_all.extend(vlist)
        page += 1

    if total is not None:
        log(f"UP主视频总数: {total}, 列出 {min(count, len(vlist_all))} 条:")
    for i, v in enumerate(vlist_all[:count], 1):
        print(f"{i}. [{v.get('length','?')}] {v.get('title','')}")
        print(f"   BV: {v.get('bvid','?')} | UP: {v.get('author','')} | 播放: {v.get('play','?')} | 评论: {v.get('comment',0)}")


# =====================================================================
# 子命令: login (扫码登录)
# =====================================================================

def cmd_login(cookie_file=None):
    cookie_file = cookie_file or LOGINFILE
    qr_html = os.path.join(HOME_DIR, "bilibili-login-qr.html")
    os.makedirs(os.path.dirname(cookie_file), exist_ok=True)
    print("==============================================")
    print(" B站扫码登录")
    print(f" cookies 保存到: {cookie_file}")
    print("==============================================")

    log(">>> 获取登录二维码...")
    gen = http_get_json("https://passport.bilibili.com/x/passport-login/web/qrcode/generate",
                        referer="https://www.bilibili.com/")
    qrcode_key = (gen.get("data") or {}).get("qrcode_key")
    qr_url = (gen.get("data") or {}).get("url")
    if not qrcode_key:
        sys.exit("❌ 获取二维码失败")

    log(f">>> 生成二维码页面: {qr_html}")
    _write_qr_html(qr_url, qr_html)
    print(">>> 请打开二维码页面扫码:")
    print(f"    浏览器打开: {qr_html}")
    if os.path.isfile(qr_html):
        print(f"    ✅ 二维码页面已生成: {qr_html}")

    print()
    print(">>> 等待扫码确认 (最长120秒)...")
    import http.cookiejar
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    code = "-1"
    res_text = ""
    for i in range(1, 25):
        time.sleep(5)
        url = ("https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key="
               + urllib.parse.quote(qrcode_key))
        headers = {"User-Agent": UA, "Referer": "https://www.bilibili.com/",
                   "Origin": "https://www.bilibili.com"}
        req = urllib.request.Request(url, headers=headers)
        try:
            with opener.open(req, timeout=20) as resp:
                res_text = resp.read().decode("utf-8", errors="replace")
        except Exception:
            res_text = ""
        try:
            code = str((json.loads(res_text).get("data") or {}).get("code", "-1"))
        except Exception:
            code = "-1"
        if code == "0":
            print(">>> ✅ 扫码确认! 正在获取登录态...")
            break
        if code == "86038":
            sys.exit(">>> 二维码已失效, 请重新运行登录命令")
        if code == "86090":
            print(f">>> 已扫码, 等待确认...({i}) 请在手机上点确认")
        else:
            print(f">>> 等待扫码...({i})")

    if code != "0":
        sys.exit("❌ 登录超时或失败")

    cross_url = ""
    try:
        cross_url = (json.loads(res_text).get("data") or {}).get("url", "")
    except Exception:
        pass
    if cross_url:
        log(">>> 访问 crossDomain 获取 SESSDATA...")
        try:
            req = urllib.request.Request(cross_url, headers={"User-Agent": UA,
                                                             "Referer": "https://www.bilibili.com/"})
            with opener.open(req, timeout=20):
                pass
        except Exception:
            pass
    sessdata = any(c.name == "SESSDATA" and c.value for c in jar)
    if sessdata:
        write_netscape(cookie_file, jar)
        print()
        print(f"✅ 登录成功! cookies 已保存: {cookie_file}")
        print("  现在可用 bilidown 下载高清 (720P+/1080P)")
    else:
        sys.exit("❌ 未获取到 SESSDATA cookie")


def _write_qr_html(url, path):
    try:
        import qrcode  # type: ignore
        img = qrcode.make(url)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        b64 = base64.b64encode(buf.getvalue()).decode()
        img_html = f'<img src="data:image/png;base64,{b64}"/>'
    except ImportError:
        img_html = (f'<p style="font-size:14px;word-break:break-all;color:#333">'
                    f'未安装 qrcode 库, 请在手机浏览器打开: <br/><a href="{html.escape(url)}">'
                    f'{html.escape(url)}</a></p><p class="tip">或执行: pip install qrcode 后重新登录生成二维码</p>')
    html_doc = f"""<!DOCTYPE html>
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
{img_html}
<p class="tip">登录成功后 cookies 将保存到<br/><code>~/.cache/bilibili-login-cookies.txt</code></p>
<p class="tip">如二维码失效，重新运行 <code>bilidown login</code></p>
</div></body></html>"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(html_doc)
    log("HTML 生成完成")


# =====================================================================
# 子命令: preview
# =====================================================================

def cmd_preview(text):
    bv, pnum, _ = normalize_input(text)
    if not bv:
        sys.exit(f"ERROR: 无法从输入提取 BV 号: {text}")
    pnum = int(pnum or 1)
    ck = get_cookies(verbose=False)
    view = http_get_json("https://api.bilibili.com/x/web-interface/view", {"bvid": bv},
                         cookies=ck)
    data = view.get("data") or {}
    pic = (data.get("pic") or "").replace("http://", "https://")
    title = data.get("title", "")
    if not pic:
        sys.exit("ERROR: 获取视频信息失败(可能被风控)")
    pagelist = api_pagelist(bv, ck)
    pages = (pagelist.get("data") or []) if pagelist.get("code") == 0 else []
    part_count = len(pages) or 1

    parts_html = ""
    if part_count > 1:
        rows = []
        for p in pages:
            dur = p.get("duration", 0)
            m, s = divmod(dur, 60)
            rows.append(
                f"<div class='part' data-p='{p.get('page')}'><span class='pnum'>P{p.get('page')}</span> "
                f"<span class='ptitle'>{html.escape(p.get('part',''))}</span> "
                f"<span class='pdur'>{m}:{s:02d}</span></div>")
        parts_html = "".join(rows)

    os.makedirs(OUTBASE, exist_ok=True)
    outfile = os.path.join(OUTBASE, f"{bv}_p{pnum}.html")
    player = f"https://www.bilibili.com/blackboard/webplayer/mbplayer.html?bvid={bv}&p={pnum}"
    title_esc = html.escape(title)
    badge = f"{part_count} 个分P" + (f" · P{pnum}" if pnum else "")
    doc = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>{title_esc}</title>
<style>
* {{ margin:0; padding:0; box-sizing:border-box; }}
body {{ background:#181a20; color:#eee; font-family:-apple-system,"PingFang SC","Noto Sans CJK SC",sans-serif; min-height:100vh; }}
.cover-link {{ display:block; position:relative; width:100%; aspect-ratio:16/9; background:#000; overflow:hidden; text-decoration:none; }}
.cover-link img {{ display:block; width:100%; height:100%; object-fit:cover; opacity:.6; transition:opacity .2s; }}
.cover-link:active img {{ opacity:.9; }}
.cover-mask {{ position:absolute; inset:0; background:linear-gradient(180deg,transparent 30%,rgba(24,26,32,.92) 100%); pointer-events:none; }}
.play-btn {{ position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); width:64px; height:64px; border-radius:50%; background:rgba(251,114,153,.92); color:#fff; font-size:26px; display:flex; align-items:center; justify-content:center; box-shadow:0 2px 12px rgba(0,0,0,.4); pointer-events:none; }}
.tap-hint {{ text-align:center; color:#99a2b5; font-size:12px; padding:8px 0 4px; }}
.cover-info {{ position:absolute; left:0; right:0; bottom:0; padding:14px 16px 18px; pointer-events:none; }}
.cover-info .badge {{ display:inline-block; background:#fb7299; color:#fff; font-size:11px; padding:2px 8px; border-radius:10px; margin-bottom:8px; }}
.cover-info h1 {{ font-size:17px; line-height:1.4; font-weight:600; text-shadow:0 1px 3px rgba(0,0,0,.6); }}
.section {{ padding:12px 16px; }}
.section h2 {{ font-size:13px; color:#99a2b5; margin-bottom:8px; font-weight:500; }}
.parts {{ display:flex; flex-direction:column; gap:6px; max-height:280px; overflow-y:auto; -webkit-overflow-scrolling:touch; }}
.part {{ display:flex; align-items:center; gap:10px; padding:8px 10px; background:#23262e; border-radius:8px; font-size:13px; }}
.part .pnum {{ color:#fb7299; font-weight:600; flex-shrink:0; }}
.part .ptitle {{ flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }}
.part .pdur {{ color:#7a8296; flex-shrink:0; font-size:12px; }}
.footer {{ padding:16px; text-align:center; color:#5a6275; font-size:11px; }}
</style>
</head>
<body>
<a class="cover-link" href="{player}">
  <img src="{pic}" alt="封面" onerror="this.style.display='none'">
  <div class="cover-mask"></div>
  <div class="play-btn">▶</div>
  <div class="cover-info">
    <span class="badge">{badge}</span>
    <h1>{title_esc}</h1>
  </div>
</a>
<div class="tap-hint">👆 点击封面播放视频</div>
<div class="section">
  <h2>分P列表</h2>
  <div class="parts">{parts_html or '<div class="part"><span class="pnum">P1</span><span class="ptitle">单P视频</span></div>'}</div>
</div>
<div class="footer">B站预览 · bilibili-downloader-cli</div>
</body>
</html>"""
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(doc)
    log(f">>> 预览页已生成: {outfile}")
    log(f">>> 直链: {player}")
    print(f"file://{outfile}")


# =====================================================================
# 子命令: dl (下载)
# =====================================================================

def pick_stream(vids, max_res, prefer_avc=True):
    """从 dash video 流中挑选: H.264 优先, 分辨率 <= max_res。返回 dict。"""
    target_qn = {"480": 32, "720": 64, "1080": 80}.get(str(max_res), 80)
    avc = [v for v in vids if str(v.get("codecs", "")).startswith("avc")]
    pool = avc if (prefer_avc and avc) else vids
    pool = sorted(pool, key=lambda v: -(v.get("id") or 0))
    for v in pool:
        if (v.get("id") or 0) <= target_qn:
            return v
    return pool[-1] if pool else None


def run_ffmpeg(args, timeout=600):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout).returncode


def download_audio(bv, pnum, outdir, ck, cut=None, title_override=None):
    ffmpeg, ffprobe = check_ffmpeg()
    cid, title = get_page_info(bv, pnum, ck)
    title = safe_name(title_override or title)
    d = api_playurl(bv, cid, qn=16, cookies=ck)
    if d.get("code") != 0:
        sys.exit(f"ERROR: API错误 code={d.get('code')} {d.get('message')}")
    auds = ((d.get("data") or {}).get("dash") or {}).get("audio") or []
    if not auds:
        sys.exit("ERROR: 获取音频直链失败")
    aurl = auds[0]["baseUrl"]

    out = os.path.join(outdir, f"{title}.m4a")
    if pnum:
        out = os.path.join(outdir, f"P{pnum}_{title}.m4a")
    if cut:
        out = out[:-4] + f"_[{cut[0]}s-{cut[0]+cut[1]}s].m4a"
    afile = os.path.join(outdir, f".audio_tmp_{pnum}.m4s")

    print(f">>> 下载音频 {('P'+str(pnum)) if pnum else ''}(API直链)...")
    try:
        download_to(aurl, afile)
    except Exception:
        os.remove(afile) if os.path.exists(afile) else None
        sys.exit("ERROR: 音频流下载失败")
    if cut:
        print(f">>> 截取片段: {cut[0]}s 起, 时长 {cut[1]}s...")
        rc = run_ffmpeg([ffmpeg, "-y", "-ss", str(cut[0]), "-i", afile, "-t", str(cut[1]),
                         "-c", "copy", "-movflags", "+faststart", out])
        if rc != 0:
            os.remove(afile) if os.path.exists(afile) else None
            sys.exit("ERROR: 音频截取失败")
    else:
        rc = run_ffmpeg([ffmpeg, "-y", "-i", afile, "-c", "copy", "-movflags", "+faststart", out])
        if rc != 0:
            os.remove(afile) if os.path.exists(afile) else None
            sys.exit("ERROR: 音频转 m4a 失败")
    os.remove(afile) if os.path.exists(afile) else None
    if os.path.isfile(out):
        print(f">>> ✅ 已生成: {os.path.basename(out)} ({os.path.getsize(out)/1048576:.1f}M)")
    else:
        sys.exit(">>> ⚠️ 产物不存在")


def download_video(bv, pnum, outdir, ck, container="mp4", max_res=480, cut=None, title_override=None):
    ffmpeg, ffprobe = check_ffmpeg()
    cid, title = get_page_info(bv, pnum, ck)
    title = safe_name(title_override or title)
    d = api_playurl(bv, cid, qn=80, cookies=ck)
    if d.get("code") != 0:
        sys.exit(f"ERROR: API错误 code={d.get('code')} {d.get('message')}")
    dash = (d.get("data") or {}).get("dash") or {}
    vids, auds = dash.get("video") or [], dash.get("audio") or []
    if not vids or not auds:
        sys.exit("ERROR: 获取视频/音频直链失败(可能需登录或付费)")
    v = pick_stream(vids, max_res)
    aurl = auds[0]["baseUrl"]
    vurl = v["baseUrl"]

    print(f">>> [1/2] {('P'+str(pnum)) if pnum else ''}下载视频流 (max {max_res}p, API直链)...")
    vfile = os.path.join(outdir, f".video_tmp_{pnum}.m4s")
    try:
        download_to(vurl, vfile)
    except Exception:
        os.remove(vfile) if os.path.exists(vfile) else None
        sys.exit("ERROR: 视频流下载失败")

    print(f">>> [2/2] {('P'+str(pnum)) if pnum else ''}下载音频流...")
    afile = os.path.join(outdir, f".audio_tmp_{pnum}.m4s")
    try:
        download_to(aurl, afile)
    except Exception:
        os.remove(vfile) if os.path.exists(vfile) else None
        os.remove(afile) if os.path.exists(afile) else None
        sys.exit("ERROR: 音频流下载失败")

    out = os.path.join(outdir, f"{title}.{container}")
    if pnum:
        out = os.path.join(outdir, f"P{pnum}_{title}.{container}")
    if cut:
        stem, ext = os.path.splitext(out)
        out = f"{stem}_[{cut[0]}s-{cut[0]+cut[1]}s]{ext}"

    print(f">>> 合并 → {os.path.basename(out)}")
    vcodec = ffprobe_field(ffprobe, vfile, "v:0", "codec_name") or "unknown"
    print(f"    诊断: 视频流编码={vcodec}")

    cut1 = ["-ss", str(cut[0])] * 2 if cut else []
    cutout = ["-t", str(cut[1])] if cut else []
    if cut:
        print(f">>> 截取片段: {cut[0]}s 起, 时长 {cut[1]}s...")

    ok = False
    if container == "mkv":
        ok = run_ffmpeg([ffmpeg, "-y"] + cut1[:2] + ["-i", vfile] + cut1[2:] + ["-i", afile]
                        + cutout + ["-c", "copy", out]) == 0
    elif vcodec in ("h264",) or "avc" in vcodec:
        ok = run_ffmpeg([ffmpeg, "-y"] + cut1[:2] + ["-i", vfile] + cut1[2:] + ["-i", afile]
                        + cutout + ["-map", "0:v:0", "-map", "1:a:0",
                                    "-c:v", "copy", "-c:a", "copy", "-movflags", "+faststart", out]) == 0
    else:
        encoders = ""
        try:
            encoders = subprocess.run([ffmpeg, "-hide_banner", "-encoders"],
                                      capture_output=True, text=True, timeout=30).stdout
        except Exception:
            pass
        if "libx264" in encoders:
            print(f"    ⚠️ 视频流是 {vcodec}, 尝试用 libx264 转码为 H.264...")
            ok = run_ffmpeg([ffmpeg, "-y"] + cut1[:2] + ["-i", vfile] + cut1[2:] + ["-i", afile]
                            + cutout + ["-map", "0:v:0", "-map", "1:a:0",
                                        "-c:v", "libx264", "-preset", "fast", "-crf", "26",
                                        "-maxrate", "1200k", "-bufsize", "2400k",
                                        "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", out]) == 0
        elif "h264_videotoolbox" in encoders:
            print(f"    ⚠️ 视频流是 {vcodec}, 尝试用 h264_videotoolbox 转码为 H.264...")
            ok = run_ffmpeg([ffmpeg, "-y"] + cut1[:2] + ["-i", vfile] + cut1[2:] + ["-i", afile]
                            + cutout + ["-map", "0:v:0", "-map", "1:a:0",
                                        "-c:v", "h264_videotoolbox", "-b:v", "1200k",
                                        "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", out]) == 0
        else:
            print(f"    ⚠️ 无 H264 编码器, 原样复制 {vcodec} 流。请装完整 ffmpeg。")
            ok = run_ffmpeg([ffmpeg, "-y"] + cut1[:2] + ["-i", vfile] + cut1[2:] + ["-i", afile]
                            + cutout + ["-map", "0:v:0", "-map", "1:a:0",
                                        "-c:v", "copy", "-c:a", "copy", "-movflags", "+faststart", out]) == 0

        if ok:
            probe = subprocess.run([ffmpeg, "-i", out], capture_output=True, text=True, timeout=30)
            has_video = "Video:" in probe.stderr
            if not has_video or not os.path.isfile(out):
                ok = False
                os.remove(out) if os.path.exists(out) else None
        if not ok:
            print("    ⚠️ 转码失败(解码器不支持), 尝试重新下载 avc(H.264) 视频流...")
            d2 = api_playurl(bv, cid, qn=80, cookies=ck)
            vids2 = ((d2.get("data") or {}).get("dash") or {}).get("video") or []
            avc = [x for x in vids2 if str(x.get("codecs", "")).startswith("avc")]
            if avc:
                vfile2 = os.path.join(outdir, f".video_tmp_{pnum}_avc.m4s")
                try:
                    download_to(avc[0]["baseUrl"], vfile2)
                    print("    ✅ 拿到 avc 流, 直接合并 (免转码)...")
                    ok = run_ffmpeg([ffmpeg, "-y"] + cut1[:2] + ["-i", vfile2] + cut1[2:]
                                    + ["-i", afile] + cutout + ["-map", "0:v:0", "-map", "1:a:0",
                                                                "-c:v", "copy", "-c:a", "copy",
                                                                "-movflags", "+faststart", out]) == 0
                    os.remove(vfile2) if os.path.exists(vfile2) else None
                except Exception:
                    os.remove(vfile2) if os.path.exists(vfile2) else None
                    ok = False
            if not ok:
                print(f"    ⚠️ 无 avc 流可用, 回退原样复制 {vcodec} 流。")
                ok = run_ffmpeg([ffmpeg, "-y"] + cut1[:2] + ["-i", vfile] + cut1[2:] + ["-i", afile]
                                + cutout + ["-map", "0:v:0", "-map", "1:a:0",
                                            "-c:v", "copy", "-c:a", "copy",
                                            "-movflags", "+faststart", out]) == 0

    for tmp in (vfile, afile):
        os.remove(tmp) if os.path.exists(tmp) else None
    if os.path.isfile(out):
        sz = os.path.getsize(out) / 1048576
        actual_h = ffprobe_field(ffprobe, out, "v:0", "height")
        size_txt = f"{sz:.1f}M"
        print(f">>> ✅ {('P'+str(pnum)) if pnum else ''}已生成: {os.path.basename(out)} ({size_txt})"
              + (f" [{actual_h}p]" if actual_h else ""))
        if actual_h and str(max_res).isdigit() and int(actual_h) < int(max_res):
            print(f"    ⚠️ 源文件最高仅 {actual_h}p (低于请求的 {max_res}p), 已下载最高可用。")
    else:
        print(">>> ⚠️ 合并产物不存在")


def parse_range(text):
    m = re.fullmatch(r"(\d+(?::\d+)?)-(\d+(?::\d+)?)", text or "")
    if not m:
        sys.exit(f"ERROR: 截取区间格式错误: '{text}' (示例: 1:30-2:45 或 90-165)")

    def to_sec(t):
        if ":" in t:
            mm, ss = t.split(":")
            return int(mm) * 60 + int(ss)
        return int(t)

    start, end = to_sec(m.group(1)), to_sec(m.group(2))
    if end <= start:
        sys.exit(f"ERROR: 截取区间无效: {text} (结束必须大于开始)")
    return start, end - start


def cmd_dl(argv):
    if len(argv) < 1:
        sys.exit('用法: bilidown dl "<URL|BV号>" [audio|video|list] [输出目录] [容器mp4|mkv] [分辨率] [分P号] [截取区间]')
    text = argv[0]
    mode = argv[1] if len(argv) > 1 else "audio"
    outdir = argv[2] if len(argv) > 2 and argv[2] else WORK
    cut = None
    if len(argv) > 6 and argv[6]:
        cut = parse_range(argv[6])

    # 智能参数解析: 兼容 <URL> <mode> [outdir] [容器] [分辨率] [分P号] [截取]
    if len(argv) > 3 and argv[3] in ("mp4", "mkv"):
        container, res_max, part_num = argv[3], argv[4] if len(argv) > 4 else "480", argv[5] if len(argv) > 5 else ""
    elif len(argv) > 3 and argv[3].isdigit():
        container, res_max, part_num = "mp4", argv[3], argv[4] if len(argv) > 4 else ""
    else:
        container, res_max, part_num = "mp4", argv[4] if len(argv) > 4 else "480", argv[5] if len(argv) > 5 else ""
    if not res_max:
        res_max = "480"

    # 相对路径转绝对
    if outdir != WORK and not os.path.isabs(outdir):
        outdir = os.path.join(os.getcwd(), outdir)
        log(f">>> 输出目录是相对路径, 已转为绝对路径: {outdir}")

    bv, p_from_input, _ = normalize_input(text)
    if not bv:
        sys.exit(f"ERROR: 无法提取BV号: {text}")

    ck = get_cookies()
    # 默认目录下按 BV 号建子文件夹
    final_out = outdir
    if os.path.normpath(outdir).startswith(os.path.normpath(WORK)):
        final_out = os.path.join(outdir, bv)
    os.makedirs(final_out, exist_ok=True)

    print("============================================")
    print(f" B站下载 | 模式: {mode}")
    print(f" 目标  : {text}")
    print(f" 输出  : {final_out}")
    print(f" 分辨率: {res_max}p")
    if part_num:
        print(f" 分P   : {part_num}")
    print("============================================")

    if mode in ("audio", "a"):
        if part_num == "all":
            if cut:
                sys.exit("ERROR: 截取片段不支持 all 模式, 请指定具体P号")
            d = api_pagelist(bv, ck)
            pages = (d.get("data") or []) if d.get("code") == 0 else []
            if not pages:
                sys.exit("ERROR: 无法获取分P列表")
            for i, p in enumerate(pages, 1):
                print(f"----- P{i}/{len(pages)} -----")
                try:
                    download_audio(bv, p.get("page"), final_out, ck, title_override=p.get("part"))
                except SystemExit as e:
                    print(f"⚠️ P{i} 失败: {e}")
        else:
            download_audio(bv, int(part_num) if part_num else 1, final_out, ck, cut)

    elif mode in ("video", "v"):
        if part_num == "all":
            if cut:
                sys.exit("ERROR: 截取片段不支持 all 模式, 请指定具体P号")
            d = api_pagelist(bv, ck)
            pages = (d.get("data") or []) if d.get("code") == 0 else []
            if not pages:
                sys.exit("ERROR: 无法获取分P列表")
            for i, p in enumerate(pages, 1):
                print(f"----- P{i}/{len(pages)} -----")
                try:
                    download_video(bv, p.get("page"), final_out, ck, container, res_max,
                                   title_override=p.get("part"))
                except SystemExit as e:
                    print(f"⚠️ P{i} 失败: {e}")
        else:
            download_video(bv, int(part_num) if part_num else 1, final_out, ck, container, res_max, cut)

    elif mode in ("list", "l"):
        if "space.bilibili.com" not in text and not re.fullmatch(r"\d+", text):
            sys.exit("list 模式需要 UP主空间链接 或 UID")
        ytdlp = find_tool("yt-dlp")
        if not ytdlp:
            sys.exit("ERROR: 未找到 yt-dlp, list 模式需要它。请先安装: pip install -U yt-dlp (或 apk add yt-dlp / brew install yt-dlp)")
        if re.fullmatch(r"\d+", text):
            url = f"https://space.bilibili.com/{text}/video"
        else:
            url = text
        print(f">>> 批量下载 UP主视频 > {res_max}p...")
        cookie_file = LOGINFILE if os.path.isfile(LOGINFILE) else BUFILE
        rc = subprocess.run([
            ytdlp, "--user-agent", UA,
            "--add-header", "Referer:https://www.bilibili.com/",
            "--add-header", "Origin:https://www.bilibili.com",
            "--extractor-args", "bilibili:player_client=web",
            "--retries", "8", "--fragment-retries", "8", "--no-mtime",
            "--force-overwrites", "--cookies", cookie_file,
            "-o", os.path.join(final_out, "%(title)s.%(ext)s"),
            "-f", f"ba/b[height<={res_max}]",
            "--download-archive", os.path.join(final_out, "archive.txt"),
            "--sleep-interval", "3", "--max-sleep-interval", "6",
            "--concurrent-fragments", "8", url,
        ]).returncode
        if rc != 0:
            sys.exit(f"ERROR: yt-dlp 退出码 {rc}")
    else:
        sys.exit(f"未知模式: {mode} (audio/video/list)")

    print("")
    print("============================================")
    print(" ✅ 完成! 产物清单:")
    print("============================================")
    for name in sorted(os.listdir(final_out)):
        if name in ("download.log", ".running") or name.startswith("."):
            continue
        full = os.path.join(final_out, name)
        if os.path.isfile(full):
            print(f"  {name}  ({os.path.getsize(full)/1048576:.1f}M)")


# =====================================================================
# 入口
# =====================================================================

USAGE = """bilidown - B站音视频下载 CLI (Python 跨平台版)

用法: bilidown <子命令> [参数...]

子命令:
  dl       下载音频/视频   bilidown dl <URL|BV号> [audio|video|list] [输出目录] [容器] [分辨率] [分P号] [截取区间]
  search   搜索视频         bilidown search <关键词> [条数]
  login    扫码登录解锁高清  bilidown login [cookies路径]
  formats  查询格式/画质    bilidown formats <URL|BV号>
  parts    查询分P列表      bilidown parts <URL|BV号>
  find     按歌名定位分P    bilidown find <URL|BV号> <关键词>
  preview  生成预览页       bilidown preview <URL|BV号>
  space    获取UP主视频列表  bilidown space <UID|空间URL> [条数]

通用:
  help, -h, --help        显示帮助
  version, -v, --version  显示版本

示例:
  bilidown dl "BV1GJ411x7h7" audio
  bilidown dl "BV1GJ411x7h7" video out mp4 1080
  bilidown search "卓依婷 萍聚"
  bilidown find "BV16v411L7js" "小草"
  bilidown dl "BVxxx" audio out mp4 480 1 "1:30-2:45"
"""


def main(argv):
    if not argv or argv[0] in ("help", "-h", "--help"):
        print(USAGE)
        return 0
    cmd, args = argv[0], argv[1:]
    if cmd in ("version", "-v", "--version"):
        print(f"bilidown {VERSION} (bilibili-downloader-cli, Python)")
        return 0
    try:
        if cmd in ("dl", "download", "d"):
            cmd_dl(args)
        elif cmd in ("search", "s"):
            cmd_search(args[0] if args else "", int(args[1]) if len(args) > 1 else 10)
        elif cmd in ("login", "l"):
            cmd_login(args[0] if args else None)
        elif cmd in ("formats", "fmt"):
            cmd_formats(args[0] if args else "")
        elif cmd in ("parts", "p"):
            cmd_parts(args[0] if args else "")
        elif cmd in ("find", "findpart", "f"):
            cmd_find(args[0] if args else "", args[1] if len(args) > 1 else "")
        elif cmd in ("preview", "v"):
            cmd_preview(args[0] if args else "")
        elif cmd in ("space", "sp"):
            cmd_space(args[0] if args else "", int(args[1]) if len(args) > 1 else 10)
        else:
            print(f"错误: 未知子命令 '{cmd}'", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            return 1
    except KeyboardInterrupt:
        print("\n已取消", file=sys.stderr)
        return 130
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
