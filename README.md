# ⬇️ bilidown - B站音视频下载 CLI

> **bilibili-downloader-cli** — 一条命令下载 B站音频/视频。基于官方 API 直链 + yt-dlp，内置 **HTTP 412 反爬规避** + **扫码登录解锁高清** + **AV1 自动规避** + **合集秒下（561P 不卡）** + **片段截取**。

```
bilidown dl "BV1GJ411x7h7" audio          # 下载音频
bilidown dl "BV1GJ411x7h7" video ~/Downloads mp4 1080   # 1080P 视频
bilidown search "卓依婷 萍聚"               # 搜索
bilidown find "BV16v411L7js" "小草"        # 561P 合集中按歌名定位
bilidown dl "BVxxx" audio ~/out mp4 480 1 "1:30-2:45"   # 截取片段
```

## 🖥️ 使用环境

| 环境 | 支持 | 说明 |
|------|:---:|------|
| **iSH (iOS)** | ✅ | 原生开发环境 |
| **Alpine / Debian / Ubuntu / macOS** | ✅ | 原生支持 |
| **Android (Termux)** | ✅ | `pkg install bash ffmpeg python curl` + `pip install yt-dlp` |
| **Windows + WSL** | ✅ | 推荐，`apt install` 装依赖 |
| **Windows + Git Bash / MSYS2** | ✅ | 依赖进 PATH |

> 依赖：`bash`、`yt-dlp`、`curl`、`python3`、`ffmpeg`、`ffprobe`

## 🚀 安装

```bash
git clone https://github.com/menghuanshiguang/bilibili-downloader-cli.git
cd bilibili-downloader-cli
bash install.sh          # 软链到 /usr/local/bin/bilidown
bilidown --version       # 验证
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

### dl 参数详解

```
bilidown dl <URL|BV号> [audio|video|list] [输出目录] [容器mp4|mkv] [分辨率480|720|1080] [分P号] [截取区间]
```

| 参数 | 说明 |
|------|------|
| `<URL或BV号>` | 视频链接 / b23.tv短链 / BV号 / `BVxxx?p=N` / UP主空间 |
| `audio`(默认) | 只下载音频 |
| `video` | 视频+音频合并（自动 H.264） |
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
- 🎵 **音频/视频**：m4a 提取 / mp4 合并，AV1 自动规避（优先 H.264）
- ✂️ **片段截取**：`-ss/-t` 流复制，下载即截取不浪费带宽
- 🔑 **扫码登录**：解锁高清/充电内容
- 🧩 **智能输入**：URL / 短链 / BV号 / UID / 歌名

## 📄 许可证

MIT License
