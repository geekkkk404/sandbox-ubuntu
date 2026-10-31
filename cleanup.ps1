# cleanup.ps1 —— 强制清理（异常退出后的兜底）。标准与主流程一致：清理 → 复核 → 如实报告
param([switch]$Quiet)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$InstanceDir = Join-Path $Root 'instance'
$BaseDir = Join-Path $Root 'base'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Test-Distro([string]$Name) {
    $list = @(& wsl --list --quiet 2>&1 | ForEach-Object { ("$_" -replace "`0", '').Trim() })
    return [bool]($list | Where-Object { $_ -eq $Name })
}
function Cleanup-Instance([string]$Name) {
    # 运行实例：unregister → 删 vhdx 目录 → 复查，重试 3 次
    $dir = $InstanceDir
    for ($i = 1; $i -le 3; $i++) {
        $null = & wsl --unregister $Name 2>&1
        Start-Sleep -Milliseconds 1200
        if (Test-Path $dir) {
            try { Remove-Item $dir -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Seconds 2 }
        }
        if ((-not (Test-Path $dir)) -and (-not (Test-Distro $Name))) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}
function Cleanup-Build([string]$Name) {
    # 构建实例：unregister → 删 base\build-* 目录 → 复查
    for ($i = 1; $i -le 3; $i++) {
        $null = & wsl --unregister $Name 2>&1
        Start-Sleep -Milliseconds 1200
        $dirs = @(Get-ChildItem -LiteralPath $BaseDir -Directory -Filter 'build-*' -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch { }
        }
        $left = @(Get-ChildItem -LiteralPath $BaseDir -Directory -Filter 'build-*' -ErrorAction SilentlyContinue)
        if (($left.Count -eq 0) -and (-not (Test-Distro $Name))) { return $true }
        Start-Sleep -Seconds 1
    }
    $left2 = @(Get-ChildItem -LiteralPath $BaseDir -Directory -Filter 'build-*' -ErrorAction SilentlyContinue)
    return (($left2.Count -eq 0) -and (-not (Test-Distro $Name)))
}

$allOk = $true

# 1) 运行实例 sandbox-ubuntu
$had = (Test-Distro 'sandbox-ubuntu') -or (Test-Path $InstanceDir)
if ($had) {
    if (-not $Quiet) { Write-Host '检测到沙箱实例残留，清理中...' -ForegroundColor Yellow }
    if (Cleanup-Instance 'sandbox-ubuntu') {
        if (-not $Quiet) { Write-Host '沙箱实例已销毁：注册表项与 instance\ 均已删除，复核确认无残留' -ForegroundColor Green }
    } else {
        Write-Host '[警告] 沙箱实例清理未完成——发行版或 instance\ 仍在！可关闭所有 WSL 终端后重试，或重启电脑后再试。' -ForegroundColor Red
        $allOk = $false
    }
} else {
    if (-not $Quiet) { Write-Host '沙箱实例：无残留' -ForegroundColor DarkGray }
}

# 2) 构建实例 sandbox-base-build + base\build-* 目录
$buildLeft = (Test-Distro 'sandbox-base-build') -or (@(Get-ChildItem -LiteralPath $BaseDir -Directory -Filter 'build-*' -ErrorAction SilentlyContinue).Count -gt 0)
if ($buildLeft) {
    if (-not $Quiet) { Write-Host '检测到母版构建实例残留，清理中...' -ForegroundColor Yellow }
    if (Cleanup-Build 'sandbox-base-build') {
        if (-not $Quiet) { Write-Host '构建实例已销毁，复核确认无残留' -ForegroundColor Green }
    } else {
        Write-Host '[警告] 构建实例清理未完成——发行版或 base\build-* 仍在！' -ForegroundColor Red
        $allOk = $false
    }
} else {
    if (-not $Quiet) { Write-Host '构建实例：无残留' -ForegroundColor DarkGray }
}

# 说明：母版 base\base-*.tar、下载缓存 download\、token.txt、logs\ 一律不动
if (-not $Quiet) { Write-Host '（母版 base\、下载缓存 download\、token.txt、logs\ 未触碰）' -ForegroundColor DarkGray }
if ($allOk) { exit 0 } else { exit 1 }
