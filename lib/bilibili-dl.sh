#!/usr/bin/env bash
# =====================================================================
# bilibili-dl.sh - B站音频/视频下载脚本 (Minis / iSH - Alpine Linux)
# 基于 yt-dlp，内置 B站反爬(412)规避参数 + buvid cookie 自动获取
#
# 用法:
#   bilibili-dl.sh <视频URL|BV号> [audio|video|list] [输出目录] [容器mp4|mkv] [最高分辨率] [分P号]
#
# 模式: audio(默认,只要音频) | video(视频+音频合并) | list(批量UP主)
# 分辨率: 480(默认游客) | 720 | 1080  (720+ 需登录, 见 bilibili-login.sh)
# 分P:   P号(如 2) 只下第2P; all 逐P下载全部; 空=第1P
#
# v3.5.0 修复:
#   - all 模式改为逐P循环下载, 每P独立临时文件(不再互相覆盖)
#   - 编码检测改用 ffprobe (修复诊断编码为空bug)
#   - 默认目录下按 BV 号建子文件夹(不再混文件)
#   - 合并后校验实际分辨率, 低于请求时提示源文件限制
#   - 每P完成打印摘要, 全程日志写入 <输出目录>/download.log
# =====================================================================
set -euo pipefail

# ---------- 配置 ----------
WORK="${HOME:-/root}/B站音频下载"
YTDLP="$(command -v yt-dlp)"
FFMPEG="$(command -v ffmpeg)"
FFPROBE="$(command -v ffprobe)"
BUFILE="${HOME:-/root}/.cache/bilibili-buvid.txt"
LOGINFILE="${HOME:-/root}/.cache/bilibili-login-cookies.txt"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
mkdir -p "$WORK" "${HOME:-/root}/.cache"

# ---------- 分辨率映射 ----------
# ⚠️ AV1 规避: 优先选 H.264(avc1) 编码, 否则 iSH 精简 ffmpeg 无法解码 AV1 会转码失败
RES_MAX="${5:-480}"
case "$RES_MAX" in
    1080|720) RES_EXPR="bv*[height<=${RES_MAX}][vcodec~='^avc']/bv*[height<=${RES_MAX}]" ;;
    *)        RES_EXPR="bv*[height<=480][vcodec~='^avc']/bv*[height<=480]" ;;
esac

# ---------- cookies 准备: 优选登录, 回落 buvid ----------
get_cookies() {
    local ck=""
    if [[ -s "$LOGINFILE" ]]; then
        ck="$LOGINFILE"
        echo ">>> 使用登录 cookies (高清可用)" >&2
    else
        if [[ ! -s "$BUFILE" ]]; then
            echo ">>> 获取 buvid cookie..." >&2
            curl -s -c "$BUFILE" -A "$UA" "https://www.bilibili.com/" -o /dev/null
            chmod 600 "$BUFILE" 2>/dev/null || true
        fi
        ck="$BUFILE"
    fi
    echo "$ck"
}

# ---------- 标准化 URL ----------
normalize_url() {
    local input="$1"
    if [[ "$input" =~ ^BV[0-9A-Za-z]{10,}(\?p=[0-9]+)?$ ]]; then
        echo "https://www.bilibili.com/video/$input"
    elif [[ "$input" =~ b23\.tv ]]; then
        curl -s -o /dev/null --max-redirs 5 -A "$UA" -w "%{url_effective}" -L "$input"
    elif [[ "$input" =~ ^[0-9]{6,}$ ]]; then
        echo "https://space.bilibili.com/$input/video"
    else
        echo "$input"
    fi
}

# ---------- 清理文件名中的危险字符 ----------
safe_name() {
    echo "$1" | tr -d '/\\:*?"<>|'
}

# ---------- 读取标题 ----------
fetch_title() {
    local url="$1" ck="$2"
    shift 2
    local extra=("$@")
    yt-dlp "${ARGS[@]}" --cookies "$ck" "${extra[@]}" --skip-download --print "%(title)s" "$url" 2>/dev/null
}

# ---------- 获取分P数 (all 模式用) ----------
get_part_count() {
    local url="$1"
    local n
    n="$(yt-dlp "${ARGS[@]}" --cookies "$CK" --skip-download --print "%(playlist_count)s" "$url" 2>/dev/null | grep -E '^[0-9]+$' | head -1 || true)"
    echo "${n:-1}"
}

# ---------- 循环下载全部P, 单P失败不中断 ----------
download_all_parts() {
    local url="$1" outdir="$2" ck="$3" mode="$4" container="$5"
    local n i rc=0
    n="$(get_part_count "$url")"
    echo ">>> 共 $n 个分P, 逐P下载..."
    for i in $(seq 1 "$n"); do
        echo "----- P$i/$n -----"
        if [[ "$mode" == "video" ]]; then
            download_video "$url" "$outdir" "$ck" "$container" "$i" || { echo "⚠️ P$i 失败, 继续下一P"; rc=1; }
        else
            download_audio "$url" "$outdir" "$ck" "$i" || { echo "⚠️ P$i 失败, 继续下一P"; rc=1; }
        fi
    done
    return $rc
}

# ---------- 用 ffprobe 读流属性 ----------
probe() {  # probe <file> <stream> <field>
    "$FFPROBE" -v error -select_streams "$2" -show_entries "stream=$3" \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1 || true
}

# ---------- 视频+音频下载并合并 (API直链方案, 绕开 yt-dlp 合集遍历卡死) ----------
download_video() {
    local url="$1" outdir="$2" ck="$3"
    local container="${4:-mp4}" part_num="${5:-}"
    local cut_start="${6:-}" cut_dur="${7:-}"
    local bv pnum resp cid title vurl aurl vfile afile out
    : > "$outdir/.running"

    bv="$(echo "$url" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
    [[ -z "$bv" ]] && { echo "ERROR: 无法提取BV号: $url" >&2; return 1; }
    pnum="${part_num:-1}"

    # 1. pagelist: 拿 cid + 标题
    resp="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/pagelist" \
        --data-urlencode "bvid=$bv" -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$ck" || true)"
    cid="$(echo "$resp" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
pages=d.get('data') or []
t=[p for p in pages if p.get('page')==int('$pnum')]
print(t[0]['cid'] if t else '')
" 2>/dev/null || true)"
    [[ -z "$cid" ]] && { echo "ERROR: 获取cid失败(风控或P$pnum不存在)" >&2; return 1; }
    title="$(echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pages=d.get('data') or []
t=[p for p in pages if p.get('page')==int('$pnum')]
print(t[0]['part'] if t else 'P$pnum')
" 2>/dev/null || echo "P$pnum")"
    title="$(safe_name "${title:-P$pnum}")"

    # 2. playurl: 拿视频+音频直链 (qn=80 最高, fourk=1)
    local streams
    streams="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/playurl" \
        --data-urlencode "bvid=$bv" --data-urlencode "cid=$cid" \
        --data-urlencode "qn=80" --data-urlencode "fnval=16" --data-urlencode "fourk=1" \
        -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$ck" \
        | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
if d.get('code')!=0: sys.exit(1)
data=d.get('data') or {}
dash=data.get('dash') or {}
vids=dash.get('video') or []
auds=dash.get('audio') or []
if not vids or not auds: sys.exit(1)
# 优先 H.264, 画质<=目标
target_qn={'480':32,'720':64,'1080':80}.get('$RES_MAX', 80)
avc=[v for v in vids if str(v.get('codecs','')).startswith('avc')]
pool=avc or vids
pool=sorted(pool, key=lambda v:-(v.get('id') or 0))
best=next((v for v in pool if (v.get('id') or 0)<=target_qn), pool[-1])
print(best['baseUrl'])
print(auds[0]['baseUrl'])
" 2>/dev/null || true)"
    vurl="$(echo "$streams" | sed -n 1p)"
    aurl="$(echo "$streams" | sed -n 2p)"
    [[ -z "$vurl" || -z "$aurl" ]] && { echo "ERROR: 获取视频/音频直链失败(可能需登录或付费)" >&2; return 1; }

    echo ">>> [1/2] ${part_num:+P$part_num }下载视频流 (max ${RES_MAX}p, API直链)..."
    vfile="$outdir/.video_tmp_${pnum}.m4s"
    timeout 180 curl -s --max-time 170 -e "https://www.bilibili.com/" -H "User-Agent: $UA" -o "$vfile" "$vurl" || { echo "ERROR: 视频流下载失败" >&2; rm -f "$vfile"; return 1; }

    echo ">>> [2/2] ${part_num:+P$part_num }下载音频流..."
    afile="$outdir/.audio_tmp_${pnum}.m4s"
    timeout 180 curl -s --max-time 170 -e "https://www.bilibili.com/" -H "User-Agent: $UA" -o "$afile" "$aurl" || { echo "ERROR: 音频流下载失败" >&2; rm -f "$vfile" "$afile"; return 1; }

    if [[ -z "$vfile" || -z "$afile" ]]; then
        echo "ERROR: 流下载不完整 video='${vfile:-无}' audio='${afile:-无}'" >&2
        return 1
    fi

    out="${outdir}/${title}.${container}"
    [[ -n "$part_num" ]] && out="${outdir}/P${part_num}_${title}.${container}"
    if [[ -n "$cut_start" && -n "$cut_dur" ]]; then
        out="${out%.${container}}_[${cut_start}s-$((${cut_start}+${cut_dur}))s].${container}"
    fi

    echo ">>> 合并 → $(basename "$out")"
    echo "    视频: $(basename "$vfile") ($(du -h "$vfile"|cut -f1))"
    echo "    音频: $(basename "$afile") ($(du -h "$afile"|cut -f1))"

    # 编码检测 (ffprobe, 稳定可靠)
    local vcodec="$(probe "$vfile" v:0 codec_name)"
    vcodec="${vcodec:-unknown}"
    echo "    诊断: 视频流编码=${vcodec}"

    # 截取参数: 双输入都 seek, 输出限长
    local CUT1="" CUT2="" CUTOUT=""
    if [[ -n "$cut_start" && -n "$cut_dur" ]]; then
        CUT1="-ss $cut_start"
        CUT2="-ss $cut_start"
        CUTOUT="-t $cut_dur"
        echo ">>> 截取片段: ${cut_start}s 起, 时长 ${cut_dur}s..."
    fi

    case "$container" in
        mkv)
            "$FFMPEG" -y $CUT1 -i "$vfile" $CUT2 -i "$afile" $CUTOUT -c copy "$out" 2>&1 | tail -3
            ;;
        *)
            if [[ "$vcodec" == h264 || "$vcodec" == *avc* ]]; then
                "$FFMPEG" -y $CUT1 -i "$vfile" $CUT2 -i "$afile" $CUTOUT \
                    -map 0:v:0 -map 1:a:0 \
                    -c:v copy -c:a copy -movflags +faststart \
                    "$out" 2>&1 | tail -3
            else
                local H264_ENC="" ENCODERS
                ENCODERS="$("$FFMPEG" -hide_banner -encoders 2>/dev/null)"
                if [[ "$ENCODERS" == *libx264* ]]; then
                    H264_ENC=libx264
                elif [[ "$ENCODERS" == *h264_videotoolbox* ]]; then
                    H264_ENC=h264_videotoolbox
                fi
                if [[ -n "$H264_ENC" ]]; then
                    echo "    ⚠️ 视频流是 ${vcodec}, 尝试用 ${H264_ENC} 转码为 H.264..."
                    if [[ "$H264_ENC" == "libx264" ]]; then
                        "$FFMPEG" -y $CUT1 -i "$vfile" $CUT2 -i "$afile" $CUTOUT \
                            -map 0:v:0 -map 1:a:0 \
                            -c:v libx264 -preset fast -crf 26 -maxrate 1200k -bufsize 2400k \
                            -c:a aac -b:a 96k -movflags +faststart "$out" 2>&1 | tail -3
                    else
                        "$FFMPEG" -y $CUT1 -i "$vfile" $CUT2 -i "$afile" $CUTOUT \
                            -map 0:v:0 -map 1:a:0 \
                            -c:v h264_videotoolbox -b:v 1200k \
                            -c:a aac -b:a 96k -movflags +faststart "$out" 2>&1 | tail -3
                    fi
                    # 验证转码结果: 必须同时有视频+音频流, 否则回退
                    local has_video
                    has_video="$("$FFMPEG" -i "$out" 2>&1 | grep -c 'Video:' || true)"
                    if [[ "$has_video" -eq 0 || ! -s "$out" ]]; then
                        echo "    ⚠️ ${H264_ENC} 转码失败(解码器不支持${vcodec}), 尝试重新下载 avc(H.264) 视频流..."
                        rm -f "$out"
                        local streams2 vurl2 vfile2
                        streams2="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/playurl" \
                            --data-urlencode "bvid=$bv" --data-urlencode "cid=$cid" \
                            --data-urlencode "qn=80" --data-urlencode "fnval=16" --data-urlencode "fourk=1" \
                            -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$ck" \
                            | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
if d.get('code')!=0: sys.exit(1)
dash=(d.get('data') or {}).get('dash') or {}
vids=dash.get('video') or []
auds=dash.get('audio') or []
if not vids or not auds: sys.exit(1)
avc=[v for v in vids if str(v.get('codecs','')).startswith('avc')]
best=avc[0] if avc else vids[0]
print(best['baseUrl'])
print(auds[0]['baseUrl'])
" 2>/dev/null || true)"
                        vurl2="$(echo "$streams2" | sed -n 1p)"
                        vfile2="$outdir/.video_tmp_${pnum}_avc.m4s"
                        if [[ -n "$vurl2" ]] && timeout 180 curl -s --max-time 170 -e "https://www.bilibili.com/" -H "User-Agent: $UA" -o "$vfile2" "$vurl2" 2>/dev/null && [[ -s "$vfile2" ]]; then
                            echo "    ✅ 拿到 avc 流, 直接合并 (免转码)..."
                            "$FFMPEG" -y $CUT1 -i "$vfile2" $CUT2 -i "$afile" $CUTOUT \
                                -map 0:v:0 -map 1:a:0 \
                                -c:v copy -c:a copy -movflags +faststart "$out" 2>&1 | tail -3
                            rm -f "$vfile2"
                        else
                            echo "    ⚠️ 无 avc 流可用, 回退原样复制 ${vcodec} 流。"
                            "$FFMPEG" -y $CUT1 -i "$vfile" $CUT2 -i "$afile" $CUTOUT \
                                -map 0:v:0 -map 1:a:0 \
                                -c:v copy -c:a copy -movflags +faststart "$out" 2>&1 | tail -3
                            echo "    ⚠️ 结果是 ${vcodec} 编码, 需现代播放器(VLC/mpv)或装完整ffmpeg转H264。" >&2
                        fi
                    fi
                else
                    echo "    ⚠️ 无 H264 编码器, 原样复制 ${vcodec} 流。请装完整 ffmpeg。" >&2
                    "$FFMPEG" -y $CUT1 -i "$vfile" $CUT2 -i "$afile" $CUTOUT \
                        -map 0:v:0 -map 1:a:0 \
                        -c:v copy -c:a copy -movflags +faststart "$out" 2>&1 | tail -3
                fi
            fi
            ;;
    esac

    rm -f "$vfile" "$afile" "$outdir/.running"
    if [[ -f "$out" ]]; then
        local sz="$(du -h "$out"|cut -f1)"
        local actual_h="$(probe "$out" v:0 height)"
        note ">>> ✅ ${part_num:+P$part_num }已生成: $(basename "$out") ($sz)${actual_h:+ [${actual_h}p]}"
        if [[ -n "$actual_h" && "${RES_MAX}" =~ ^[0-9]+$ && "$actual_h" -lt "$RES_MAX" ]]; then
            note "    ⚠️ 源文件最高仅 ${actual_h}p (低于请求的 ${RES_MAX}p), 已下载最高可用。"
        fi
    else
        note ">>> ⚠️ 合并产物不存在"
        return 1
    fi
}

# ---------- 音频下载 (API直链方案, 绕开 yt-dlp 合集遍历卡死) ----------
download_audio() {
    local url="$1" outdir="$2" ck="$3" part_num="${4:-}"
    local cut_start="${5:-}" cut_dur="${6:-}"
    local bv pnum resp cid title aurl out afile
    bv="$(echo "$url" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
    [[ -z "$bv" ]] && { echo "ERROR: 无法提取BV号: $url" >&2; return 1; }
    pnum="${part_num:-1}"

    # 1. pagelist: 拿 cid + 标题
    resp="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/pagelist" \
        --data-urlencode "bvid=$bv" -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$ck" || true)"
    cid="$(echo "$resp" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
pages=d.get('data') or []
t=[p for p in pages if p.get('page')==int('$pnum')]
print(t[0]['cid'] if t else '')
" 2>/dev/null || true)"
    [[ -z "$cid" ]] && { echo "ERROR: 获取cid失败(风控或P$pnum不存在)" >&2; return 1; }
    title="$(echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pages=d.get('data') or []
t=[p for p in pages if p.get('page')==int('$pnum')]
print(t[0]['part'] if t else 'P$pnum')
" 2>/dev/null || echo "P$pnum")"
    title="$(safe_name "${title:-P$pnum}")"

    # 2. playurl: 拿音频直链
    aurl="$(curl -s --max-time 15 -G "https://api.bilibili.com/x/player/playurl" \
        --data-urlencode "bvid=$bv" --data-urlencode "cid=$cid" \
        --data-urlencode "qn=16" --data-urlencode "fnval=16" \
        -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" -b "$ck" \
        | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
if d.get('code')!=0: sys.exit(1)
a=(d.get('data') or {}).get('dash',{}).get('audio') or []
print(a[0]['baseUrl'] if a else '')
" 2>/dev/null || true)"
    [[ -z "$aurl" ]] && { echo "ERROR: 获取音频直链失败" >&2; return 1; }

    # 3. 下载 + 转 m4a
    out="${outdir}/${title}.m4a"
    [[ -n "$part_num" ]] && out="${outdir}/P${part_num}_${title}.m4a"
    if [[ -n "$cut_start" && -n "$cut_dur" ]]; then
        out="${out%.m4a}_[${cut_start}s-$((${cut_start}+${cut_dur}))s].m4a"
    fi
    afile="${outdir}/.audio_tmp_${pnum}.m4s"
    echo ">>> 下载音频 ${part_num:+P$part_num }(API直链)..."
    if ! timeout 90 curl -s --max-time 80 -e "https://www.bilibili.com/" -H "User-Agent: $UA" -o "$afile" "$aurl"; then
        echo "ERROR: 音频流下载失败" >&2; rm -f "$afile"; return 1
    fi
    if [[ -n "$cut_start" && -n "$cut_dur" ]]; then
        echo ">>> 截取片段: ${cut_start}s 起, 时长 ${cut_dur}s..."
        if ! timeout 90 "$FFMPEG" -y -ss "$cut_start" -i "$afile" -t "$cut_dur" -c copy -movflags +faststart "$out" >/dev/null 2>&1; then
            echo "ERROR: 音频截取失败" >&2; rm -f "$afile"; return 1
        fi
    else
        if ! timeout 90 "$FFMPEG" -y -i "$afile" -c copy -movflags +faststart "$out" >/dev/null 2>&1; then
            echo "ERROR: 音频转 m4a 失败" >&2; rm -f "$afile"; return 1
        fi
    fi
    rm -f "$afile"
    note ">>> ✅ 已生成: $(basename "$out") ($(du -h "$out"|cut -f1))"
}

# ---------- 时间转秒: "1:30"→90, "90"→90 ----------
to_seconds() {
    local t="$1"
    if [[ "$t" =~ ^([0-9]+):([0-9]+)$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]} ))
    elif [[ "$t" =~ ^[0-9]+$ ]]; then
        echo "$t"
    else
        echo ""
    fi
}

# ---------- 截取区间解析: "1:30-2:45" → 输出 "start_sec dur_sec" ----------
parse_range() {
    local range="$1"
    local start_t end_t start_s end_s
    [[ "$range" =~ ^([0-9]+(:[0-9]+)?)-([0-9]+(:[0-9]+)?)$ ]] || {
        echo "ERROR: 截取区间格式错误: '$range' (示例: 1:30-2:45 或 90-165)" >&2
        return 1
    }
    start_t="${BASH_REMATCH[1]}"
    end_t="${BASH_REMATCH[3]}"
    start_s="$(to_seconds "$start_t")"
    end_s="$(to_seconds "$end_t")"
    [[ -n "$start_s" && -n "$end_s" && "$end_s" -gt "$start_s" ]] || {
        echo "ERROR: 截取区间无效: $range (结束必须大于开始)" >&2
        return 1
    }
    echo "$start_s $(( end_s - start_s ))"
}

# ---------- 日志: 关键摘要同时写入文件, 防 tail 截断丢信息 ----------
note() {  # note <文本...>
    local msg="$*"
    echo "$msg"
    [[ -n "${LOG:-}" ]] && echo "$msg" >> "$LOG" || true
}

# ---------- 主逻辑 ----------
[[ $# -lt 1 ]] && {
    echo "用法: bilibili-dl.sh <URL|BV号> [audio|video|list] [输出目录] [容器mp4|mkv] [分辨率480|720|1080] [分P号] [截取区间]" >&2
    echo "提示: 720P+ 需先登录 → 运行 bilibili-login.sh" >&2
    exit 1
}

INPUT="$1"
MODE="${2:-audio}"
OUTDIR="${3:-$WORK}"
CUT_RANGE="${7:-}"   # 可选: 截取区间 "1:30-2:45" 或 "90-165"
CUT_START="" CUT_DUR=""
# ⚠️ 相对路径防御: 转绝对路径, 防止 mkdir 与写入路径错位(文件"已生成"却找不到)
if [[ "$OUTDIR" != /* && "$OUTDIR" != "$WORK" ]]; then
    OUTDIR="$(pwd)/$OUTDIR"
    echo ">>> 输出目录是相对路径, 已转为绝对路径: $OUTDIR" >&2
fi
# ⚠️ 智能参数解析: 兼容三种调用方式
#   官方: <URL> <mode> [outdir] [容器mp4|mkv] [分辨率] [分P号]
#   习惯: <URL> <mode> [outdir] [分辨率] [分P号]   (容器省略, 默认mp4)
#   占位: <URL> <mode> [outdir] "" [分辨率] [分P号] (容器传空串)
if [[ "${4:-}" == "mp4" || "${4:-}" == "mkv" ]]; then
    CONTAINER="${4:-mp4}"
    RES_MAX="${5:-480}"
    PART_NUM="${6:-}"
elif [[ "${4:-}" =~ ^[0-9]+$ ]]; then
    CONTAINER="mp4"
    RES_MAX="${4:-480}"
    PART_NUM="${5:-}"
else
    # $4 为空或未知 → 视为容器占位, 按官方格式解析
    CONTAINER="mp4"
    RES_MAX="${5:-480}"
    PART_NUM="${6:-}"
fi

# 截取区间解析: "1:30-2:45" → CUT_START/CUT_DUR
if [[ -n "$CUT_RANGE" ]]; then
    RANGE_VALS="$(parse_range "$CUT_RANGE")" || exit 1
    CUT_START="$(echo "$RANGE_VALS" | awk '{print $1}')"
    CUT_DUR="$(echo "$RANGE_VALS" | awk '{print $2}')"
    echo ">>> 截取片段: ${CUT_START}s - $((CUT_START+CUT_DUR))s (时长 ${CUT_DUR}s)"
fi

URL="$(normalize_url "$INPUT")"
CK="$(get_cookies)"

# 默认目录下按 BV 号建子文件夹, 避免混文件
BV_ID="$(echo "$URL" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
FINAL_OUT="$OUTDIR"
if [[ "$OUTDIR" == "$WORK"* && -n "$BV_ID" ]]; then
    FINAL_OUT="$OUTDIR/$BV_ID"
fi
mkdir -p "$FINAL_OUT"

# 日志文件: 全量记录, 防 tail 截断丢信息
LOG="$FINAL_OUT/download.log"
: > "$LOG"

echo "============================================"
echo " B站下载 | 模式: $MODE"
echo " 目标  : $URL"
echo " 输出  : $FINAL_OUT"
echo " 分辨率: ${RES_MAX}p"
[[ -n "$PART_NUM" ]] && echo " 分P   : $PART_NUM"
echo "============================================"

# 公共参数数组
ARGS=(
    --user-agent "$UA"
    --add-header "Referer:https://www.bilibili.com/"
    --add-header "Origin:https://www.bilibili.com"
    --extractor-args "bilibili:player_client=web"
    --retries 8 --fragment-retries 8 --no-mtime
    --force-overwrites
)

case "$MODE" in
    audio|a)
        if [[ "$PART_NUM" == "all" ]]; then
            if [[ -n "$CUT_START" ]]; then
                echo "ERROR: 截取片段不支持 all 模式, 请指定具体P号" >&2; exit 1
            fi
            download_all_parts "$URL" "$FINAL_OUT" "$CK" "audio" ""
        else
            download_audio "$URL" "$FINAL_OUT" "$CK" "$PART_NUM" "$CUT_START" "$CUT_DUR"
        fi
        ;;
    video|v)
        if [[ "$PART_NUM" == "all" ]]; then
            if [[ -n "$CUT_START" ]]; then
                echo "ERROR: 截取片段不支持 all 模式, 请指定具体P号" >&2; exit 1
            fi
            download_all_parts "$URL" "$FINAL_OUT" "$CK" "video" "$CONTAINER"
        else
            download_video "$URL" "$FINAL_OUT" "$CK" "$CONTAINER" "$PART_NUM" "$CUT_START" "$CUT_DUR"
        fi
        ;;
    list|l)
        [[ "$URL" =~ space\.bilibili\.com ]] || {
            echo "list 模式需要 UP主空间链接" >&2; exit 2
        }
        echo ">>> 批量下载 UP主视频 > ${RES_MAX}p..."
        yt-dlp "${ARGS[@]}" --cookies "$CK" \
            -o "$FINAL_OUT/%(title)s.%(ext)s" \
            -f "ba/b[height<=${RES_MAX}]" \
            --download-archive "$FINAL_OUT/archive.txt" \
            --sleep-interval 3 --max-sleep-interval 6 \
            --concurrent-fragments 8 \
            "$URL"
        ;;
    *)
        echo "未知模式: $MODE (audio/video/list)" >&2; exit 2
        ;;
esac

echo ""
echo "============================================"
echo " ✅ 完成！产物清单:"
echo "============================================"
ls -lh "$FINAL_OUT" | grep -vE "download\.log|\.running" | tee -a "$LOG" | tail -20
echo "完整日志: $LOG"
