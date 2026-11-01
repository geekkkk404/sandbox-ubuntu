# cleanup.ps1 —— 强制清理（异常退出后的兜底）。标准与主流程一致：清理 → 复核 → 如实报告
# 参数: -Quiet 静默模式（仅失败时输出）；-Lang zh|en 界面语言（缺省自动检测；SB_LANG 环境变量同效）
param([switch]$Quiet, [string]$Lang)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$InstanceDir = Join-Path $Root 'instance'
$BaseDir = Join-Path $Root 'base'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---- 界面语言（ISSUE-008）：-Lang > SB_LANG > 自动检测（zh* → zh，其余 → en） ----
# 检测源按稳定性排序：注册表 PreferredUILanguages → 用户语言列表首项 → CurrentUICulture 兜底（会话内可能翻转）
function Get-UiLangAuto {
    try {
        $d = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name PreferredUILanguages -ErrorAction Stop).PreferredUILanguages
        if ($d -and @($d).Count -gt 0) { if (@($d)[0] -match '^zh') { return 'zh' } else { return 'en' } }
    } catch { }
    try {
        $l = (Get-ItemProperty -Path 'HKCU:\Control Panel\International\User Profile' -Name Languages -ErrorAction Stop).Languages
        if ($l -and @($l).Count -gt 0) { if (@($l)[0] -match '^zh') { return 'zh' } else { return 'en' } }
    } catch { }
    try { if ([System.Globalization.CultureInfo]::CurrentUICulture.Name -match '^zh') { return 'zh' } } catch { }
    return 'en'
}
if ($Lang -ne 'zh' -and $Lang -ne 'en') { $Lang = $env:SB_LANG }
if ($Lang -ne 'zh' -and $Lang -ne 'en') { $Lang = Get-UiLangAuto }

# ---- 双语字符串表（键集必须一致，启动时自检） ----
$MSG_ZH = @{
    instResidue   = '检测到沙箱实例残留，清理中...'
    instDestroyed = '沙箱实例已销毁：注册表项与 instance\ 均已删除，复核确认无残留'
    instWarn      = '[警告] 沙箱实例清理未完成——发行版或 instance\ 仍在！可关闭所有 WSL 终端后重试，或重启电脑后再试。'
    instNone      = '沙箱实例：无残留'
    buildResidue  = '检测到母版构建实例残留，清理中...'
    buildOk       = '构建实例已销毁，复核确认无残留'
    buildWarn     = '[警告] 构建实例清理未完成——发行版或 base\build-* 仍在！'
    buildNone     = '构建实例：无残留'
    untouched     = '（母版 base\、下载缓存 download\、token.txt、logs\ 未触碰）'
    tableMismatch = '[FAIL] i18n 字符串表键集不一致（开发错误）'
}
$MSG_EN = @{
    instResidue   = 'Sandbox instance leftover detected, cleaning...'
    instDestroyed = 'Sandbox instance destroyed: registry entry and instance\ deleted; zero-leftover re-checked'
    instWarn      = '[WARN] Sandbox instance cleanup incomplete - the distro or instance\ still exists! Close all WSL terminals and retry, or reboot and try again.'
    instNone      = 'Sandbox instance: nothing to clean'
    buildResidue  = 'Base-image build instance leftover detected, cleaning...'
    buildOk       = 'Build instance destroyed; zero-leftover re-checked'
    buildWarn     = '[WARN] Build instance cleanup incomplete - the distro or base\build-* still exists!'
    buildNone     = 'Build instance: nothing to clean'
    untouched     = '(Untouched: base images in base\, download cache, token.txt, logs\)'
    tableMismatch = '[FAIL] i18n string table key mismatch (development error)'
}
if ((Compare-Object @($MSG_ZH.Keys) @($MSG_EN.Keys)).Count -ne 0) {
    Write-Host $MSG_ZH['tableMismatch'] -ForegroundColor Red
    exit 1
}
$MSG = $MSG_ZH; if ($Lang -eq 'en') { $MSG = $MSG_EN }

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
    if (-not $Quiet) { Write-Host $MSG['instResidue'] -ForegroundColor Yellow }
    if (Cleanup-Instance 'sandbox-ubuntu') {
        if (-not $Quiet) { Write-Host $MSG['instDestroyed'] -ForegroundColor Green }
    } else {
        Write-Host $MSG['instWarn'] -ForegroundColor Red
        $allOk = $false
    }
} else {
    if (-not $Quiet) { Write-Host $MSG['instNone'] -ForegroundColor DarkGray }
}

# 2) 构建实例 sandbox-base-build + base\build-* 目录
$buildLeft = (Test-Distro 'sandbox-base-build') -or (@(Get-ChildItem -LiteralPath $BaseDir -Directory -Filter 'build-*' -ErrorAction SilentlyContinue).Count -gt 0)
if ($buildLeft) {
    if (-not $Quiet) { Write-Host $MSG['buildResidue'] -ForegroundColor Yellow }
    if (Cleanup-Build 'sandbox-base-build') {
        if (-not $Quiet) { Write-Host $MSG['buildOk'] -ForegroundColor Green }
    } else {
        Write-Host $MSG['buildWarn'] -ForegroundColor Red
        $allOk = $false
    }
} else {
    if (-not $Quiet) { Write-Host $MSG['buildNone'] -ForegroundColor DarkGray }
}

# 说明：母版 base\base-*.tar、下载缓存 download\、token.txt、logs\ 一律不动
if (-not $Quiet) { Write-Host $MSG['untouched'] -ForegroundColor DarkGray }
if ($allOk) { exit 0 } else { exit 1 }
