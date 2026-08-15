# =====================================================================
# bilibili-downloader-cli 安装脚本 (Windows / PowerShell)
# 用法: powershell -ExecutionPolicy Bypass -File install.ps1
#
# 作用:
#   1. 把本仓库 bin/ 目录加入用户 PATH (新开终端后可直接用 bilidown)
#   2. 校验 Git Bash / WSL 可用
# 依赖: Git for Windows (https://git-scm.com/download/win) 或 WSL
# =====================================================================
$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
$bin = Join-Path $src 'bin'

# ---------- 定位 bash ----------
$bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
if (-not $bash) {
    foreach ($p in @('D:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\bin\bash.exe', "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if (Test-Path $p) { $bash = $p; break }
    }
}
if (-not $bash) {
    Write-Host '[bilidown] 未找到 Git Bash。请先安装 Git for Windows: https://git-scm.com/download/win' -ForegroundColor Red
    exit 1
}
Write-Host ">>> 使用 bash: $bash"

# ---------- 加入用户 PATH ----------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$bin*") {
    $newPath = if ([string]::IsNullOrEmpty($userPath)) { $bin } else { "$userPath;$bin" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host ">>> 已把 $bin 加入用户 PATH(新开的终端生效)"
} else {
    Write-Host ">>> $bin 已在用户 PATH 中"
}

# ---------- 验证 ----------
Write-Host ''
Write-Host '>>> 验证 bilidown --version:'
& $bash -lc "cd '$src' && bash bin/bilidown --version"
Write-Host ''
Write-Host '>>> 完成! 新开一个终端(cmd/PowerShell)即可直接使用 bilidown。'
Write-Host '>>> 示例: bilidown dl "BV1GJ411x7h7" audio'
