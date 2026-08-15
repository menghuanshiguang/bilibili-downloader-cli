# ⬇️ bilidown - B站音视频下载 CLI(Python 跨平台单文件版)

> **bilibili-downloader-cli** — 一条命令下载 B站音频/视频。基于官方 API 直链 + yt-dlp，内置 **HTTP 412 反爬规避** + **扫码登录解锁高清** + **AV1 自动规避** + **合集秒下（561P 不卡）** + **片段截取**。
>
> **v2.0.0 起为 Python 单文件实现**(`bin/bilidown.py`),Windows / macOS / Linux / iSH / Termux 一份代码通用,不再依赖 bash / curl / msys 路径转换。

```
bilidown dl "BV1GJ411x7h7" audio          # 下载音频
bilidown dl "BV1GJ411x7h7" video out mp4 1080   # 1080P 视频
bilidown search "卓依婷 萍聚"               # 搜索
bilidown find "BV16v411L7js" "小草"        # 561P 合集中按歌名定位
bilidown dl "BVxxx" audio out mp4 480 1 "1:30-2:45"   # 截取片段
```

## 🖥️ 支持环境

| 环境 | 说明 |
|------|------|
| **Windows** | ✅ Python 3.8+ 直接运行(`bilidown.cmd` 入口) |
| **macOS / Linux / WSL** | ✅ `pip` 或 install.sh 安装 |
| **iSH (iOS) / Termux (Android)** | ✅ `apk add python3 ffmpeg` / `pkg install python ffmpeg` |

### 依赖

| 工具 | 用途 | 说明 |
|------|------|------|
| **Python 3.8+** | 运行环境 | 唯一硬性要求 |
| `ffmpeg` / `ffprobe` | 音频 remux / 视频合并转码 | audio/video 模式必需,缺失时给出各平台安装指引 |
| `yt-dlp` | list(批量 UP 主空间)模式 | 仅该模式需要 |
| `qrcode`(pip) | login 扫码登录二维码图片 | 缺失时降级为链接页,不影响其他功能 |

> 不需要 bash / curl / 额外的 python3 配置——这就是跨平台重写的目的。

## 🚀 安装

### 方式一:install.sh(类 Unix)

```bash
git clone https://github.com/menghuanshiguang/bilibili-downloader-cli.git
cd bilibili-downloader-cli
bash install.sh          # 软链 bin/bilidown.py → /usr/local/bin/bilidown
bilidown --version       # 验证
```

### 方式二:install.ps1(Windows)

```powershell
git clone https://github.com/menghuanshiguang/bilibili-downloader-cli.git
cd bilibili-downloader-cli
powershell -ExecutionPolicy Bypass -File install.ps1   # 把 bin/ 加入用户 PATH
# 新开终端:
bilidown --version
```

### 方式三:不安装,直接跑

```bash
python bin/bilidown.py dl "BV1GJ411x7h7" audio     # Windows / Linux 通用
# Windows 也可以用 bin/bilidown.cmd(等价入口)
```

## 📖 子命令

| 子命令 | 说明 |
|--------|------|
| `dl` (download/d) | 下载音频/视频/批量，完整参数：`<URL> [audio\|video\|list] [输出目录] [容器] [分辨率] [分P号] [截取区间]` |
| `search` (s) | 搜索视频：`bilidown search <关键词> [条数]` |
| `login` (l) | 扫码登录解锁 720P/1080P 高清 |
| `formats` (fmt) | 查询可用格式/最高分辨率 |
| `parts` (p) | 查询分P列表（561P 秒出） |
| `find` (f) | 按关键词定位合集分P |
| `preview` (v) | 生成预览页（封面+标题+播放） |
| `space` (sp) | 获取UP主主页视频列表（wbi 签名） |

### dl 参数详解

```
bilidown dl <URL|BV号> [audio|video|list] [输出目录] [容器mp4|mkv] [分辨率480|720|1080] [分P号] [截取区间]
```

| 参数 | 说明 |
|------|------|
| `<URL或BV号>` | 视频链接 / b23.tv短链 / BV号 / `BVxxx?p=N` / UP主空间 / UID |
| `audio`(默认) | 只下载音频 |
| `video` | 视频+音频合并（自动 H.264 优先） |
| `list` | 批量下载 UP 主空间 |
| `[输出目录]` | 默认 `~/B站音频下载/`，相对路径自动转绝对 |
| `[容器]` | `mp4`(默认)/`mkv`，可省略 |
| `[分辨率]` | 默认 480；720/1080 需登录，可省略 |
| `[分P号]` | P号 / `all` / 空=第1P，可省略 |
| `[截取区间]` | `1:30-2:45` 或 `90-165`，音频视频都支持，可省略 |

## 🔑 登录解锁高清

```bash
bilidown login
# 生成二维码 HTML (~/bilibili-login-qr.html)，B站 App 扫码确认
# cookies 存 ~/.cache/bilibili-login-cookies.txt，自动启用
```

## ✨ 特性

- 🛡️ **412 反爬规避**：buvid cookie + Referer/Origin/UA + player_client=web
- ⚡ **官方 API 直链**：pagelist + playurl，561P 合集 2 秒定位，不再卡死
- 🎵 **音频/视频**：m4a 提取 / mp4 合并，AV1 自动规避（优先 H.264，转码失败自动重下 avc 流）
- ✂️ **片段截取**：`-ss/-t` 流复制，下载即截取不浪费带宽
- 🔑 **扫码登录**：解锁高清/充电内容
- 🧩 **智能输入**：URL / 短链 / BV号 / UID / 歌名
- 📦 **单文件跨平台**：一份 `bilidown.py`，Windows/macOS/Linux/iSH/Termux 通用

## 📄 许可证

MIT License
