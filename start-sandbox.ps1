# start-sandbox.ps1 —— 主入口：选版本/档案→(按需构建母版)→清理→导入全新实例→(可选身份)+验证→进入shell→退出即校验式销毁
# 参数: -Version 22.04|24.04|26.04  指定版本（缺省：交互菜单；自动化场景用上次选择或 versions.json 的 default）
#       -Profile stock|tencent|aliyun  指定新机档案（apt 源启动期对齐到目标云；缺省：菜单/上次选择/defaultProfile）
#       -SkipShell   不开交互 shell，跑完 注入/验证/清理（自动化验证用；无人值守时自动构建缺失的母版）
#       -Force       验证失败时不询问直接放弃
#       -NoIdentity  强制纯净模式（即使 token.txt 存在也不注入）
#       -ListVersions 打印支持矩阵（版本 × 新机档案）后退出
param(
    [string]$Version,
    [string]$Profile,
    [switch]$SkipShell,
    [switch]$Force,
    [switch]$NoIdentity,
    [switch]$ListVersions
)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$DistroName = 'sandbox-ubuntu'
$ManifestPath = Join-Path $Root 'versions.json'
$TokenFile = Join-Path $Root 'token.txt'
$InstanceDir = Join-Path $Root 'instance'
$LogDir = Join-Path $Root 'logs'
$SetupSh = Join-Path $Root 'setup.sh'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Test-Distro([string]$Name) {
    $list = @(& wsl --list --quiet 2>&1 | ForEach-Object { ("$_" -replace "`0", '').Trim() })
    return [bool]($list | Where-Object { $_ -eq $Name })
}
function Cleanup {
    # 校验式清理：unregister → 删 instance\ → 复查注册表与磁盘，失败重试 3 次
    # 返回 $true = 已确认零残留；$false = 没清干净（调用方必须红字报警，绝不谎报成功）
    for ($i = 1; $i -le 3; $i++) {
        $null = & wsl --unregister $DistroName 2>&1
        Start-Sleep -Milliseconds 1200
        if (Test-Path $InstanceDir) {
            try { Remove-Item $InstanceDir -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Seconds 2 }
        }
        if ((-not (Test-Path $InstanceDir)) -and (-not (Test-Distro $DistroName))) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}
function CleanupReport([bool]$Ok) {
    if ($Ok) {
        Write-Host '沙箱已销毁：实例 vhdx 与注册表项已删除，并已复核确认无残留' -ForegroundColor Green
    } else {
        Write-Host '[警告] 清理未完成——发行版或 instance\ 仍在，磁盘没有释放！' -ForegroundColor Red
        Write-Host '       处理：双击 cleanup.cmd 强制清理；下次启动也会自动重试。' -ForegroundColor Yellow
        Write-Host '       根因：请在沙箱里输 exit 退出；直接点窗口 X 会让清理代码根本没机会执行。' -ForegroundColor Yellow
    }
}
function PauseAtEnd {
    if (-not $SkipShell) { try { [void](Read-Host '按 Enter 关闭窗口') } catch { } }
}
function Get-LastVersion([object]$Manifest) {
    $stateFile = Join-Path $LogDir 'last-version.txt'
    if (Test-Path $stateFile) {
        $last = (Get-Content -LiteralPath $stateFile -Encoding UTF8 | Select-Object -First 1)
        if ($last) { $last = $last.Trim() }
        $ids = @($Manifest.versions | ForEach-Object { $_.id })
        if ($last -and ($ids -contains $last)) { return $last }
    }
    return $Manifest.default
}
function Select-VersionMenu([object]$Manifest) {
    $ids = @($Manifest.versions | ForEach-Object { $_.id })
    $default = Get-LastVersion $Manifest
    Write-Host ''
    Write-Host '选择 Ubuntu 版本（对应真实云厂商在售 LTS）:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $e = @($Manifest.versions | Where-Object { $_.id -eq $ids[$i] })[0]
        if ($ids[$i] -eq $default) {
            Write-Host ("  [{0}] {1,-6} {2}   ← 上次使用，回车默认" -f ($i + 1), $e.id, $e.name) -ForegroundColor Green
        } else {
            Write-Host ("  [{0}] {1,-6} {2}" -f ($i + 1), $e.id, $e.name) -ForegroundColor Gray
        }
    }
    $ans = Read-Host ("输入序号（回车 = {0}）" -f $default)
    $chosen = $default
    if ($ans -match '^\d+$') {
        $idx = [int]$ans - 1
        if ($idx -ge 0 -and $idx -lt $ids.Count) { $chosen = $ids[$idx] }
    }
    return $chosen
}
function Get-LastProfile([object]$Manifest) {
    $stateFile = Join-Path $LogDir 'last-profile.txt'
    $defaultProfile = $Manifest.defaultProfile
    if (-not $defaultProfile) { $defaultProfile = @($Manifest.profiles)[0].id }
    if (Test-Path $stateFile) {
        $last = (Get-Content -LiteralPath $stateFile -Encoding UTF8 | Select-Object -First 1)
        if ($last) { $last = $last.Trim() }
        $ids = @($Manifest.profiles | ForEach-Object { $_.id })
        if ($last -and ($ids -contains $last)) { return $last }
    }
    return $defaultProfile
}
function Select-ProfileMenu([object]$Manifest) {
    $ids = @($Manifest.profiles | ForEach-Object { $_.id })
    $default = Get-LastProfile $Manifest
    Write-Host ''
    Write-Host '选择新机档案（apt 源在启动期对齐到目标云的等价公网源）:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $e = @($Manifest.profiles | Where-Object { $_.id -eq $ids[$i] })[0]
        if ($ids[$i] -eq $default) {
            Write-Host ("  [{0}] {1,-8} {2}   ← 上次使用，回车默认" -f ($i + 1), $e.id, $e.name) -ForegroundColor Green
        } else {
            Write-Host ("  [{0}] {1,-8} {2}" -f ($i + 1), $e.id, $e.name) -ForegroundColor Gray
        }
    }
    $ans = Read-Host ("输入序号（回车 = {0}）" -f $default)
    $chosen = $default
    if ($ans -match '^\d+$') {
        $idx = [int]$ans - 1
        if ($idx -ge 0 -and $idx -lt $ids.Count) { $chosen = $ids[$idx] }
    }
    return $chosen
}
function Ensure-BaseTar([string]$Id, [object]$Manifest) {
    $baseTar = Join-Path $Root ('base\base-{0}.tar' -f $Id)
    if (-not (Test-Path $baseTar)) {
        if ($SkipShell) {
            Write-Host "[info] 版本 $Id 未构建母版，-SkipShell 自动构建（首次需联网下载官方 rootfs）..." -ForegroundColor Yellow
        } else {
            Write-Host "[提示] 版本 $Id 尚未构建母版（首次需联网下载官方 rootfs 并构建，约几分钟）" -ForegroundColor Yellow
            $ans = Read-Host '现在构建? [y/N]'
            if ($ans -ne 'y') {
                Write-Host '已取消。可先单独构建: powershell -NoProfile -ExecutionPolicy Bypass -File build-base.ps1 -Version <id>' -ForegroundColor Yellow
                exit 1
            }
        }
        & (Join-Path $Root 'build-base.ps1') -Version $Id
        if ($LASTEXITCODE -ne 0) {
            Write-Host '[FAIL] 母版构建失败，无法继续' -ForegroundColor Red
            exit 1
        }
    }
    # 母版完整性校验（防损坏/误改；构建产物必须带 .sha256）
    $shaFile = "$baseTar.sha256"
    if (-not (Test-Path $shaFile)) {
        Write-Host "[FAIL] 缺少母版校验文件 $shaFile —— 请重跑 build-base.ps1 -Version $Id 生成" -ForegroundColor Red
        exit 1
    }
    $expect = ((Get-Content -LiteralPath $shaFile -Encoding UTF8 | Select-Object -First 1).Trim()).Split(' ')[0].ToLower()
    Write-Host '校验母版完整性（约几秒）...'
    $got = (Get-FileHash -Algorithm SHA256 $baseTar).Hash.ToLower()
    if ($got -ne $expect) {
        Write-Host "[FAIL] 母版 SHA256 不匹配（损坏或被改动）`n  期望 $expect`n  实际 $got`n  处理: powershell -File build-base.ps1 -Version $Id -Force 重建" -ForegroundColor Red
        exit 1
    }
    Write-Host ("母版完整性 OK ({0}...)" -f $got.Substring(0, 16)) -ForegroundColor Green
}

# ---- 支持矩阵 ----
if (-not (Test-Path $ManifestPath)) {
    Write-Host "[FAIL] 缺少支持矩阵: $ManifestPath" -ForegroundColor Red
    exit 1
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ids = @($Manifest.versions | ForEach-Object { $_.id })

if ($ListVersions) {
    Write-Host '支持矩阵（来源均为 Ubuntu 官方 rootfs，SHA256 固定于 versions.json）:' -ForegroundColor Cyan
    foreach ($e in $Manifest.versions) {
        $built = Test-Path (Join-Path $Root ('base\base-{0}.tar' -f $e.id))
        $mark = ''
        if ($built) { $mark = '  [母版已构建]' }
        if ($e.id -eq $Manifest.default) { $mark = "$mark  [默认]" }
        Write-Host ("  {0,-6} {1}{2}" -f $e.id, $e.name, $mark)
    }
    Write-Host ''
    Write-Host '新机档案（profile，apt 源在启动期对齐到目标云的等价公网源）:' -ForegroundColor Cyan
    $defProf = Get-LastProfile $Manifest
    foreach ($p in $Manifest.profiles) {
        $mark = ''
        if ($p.id -eq $defProf) { $mark = '  [默认]' }
        Write-Host ("  {0,-8} {1,-6} {2}{3}" -f $p.id, $p.mirror, $p.name, $mark)
    }
    exit 0
}

Write-Host '=== sandbox-ubuntu · 一次性全新 Ubuntu 云机模拟器 ===' -ForegroundColor Cyan

# ---- [1/6] 环境检查：WSL 可用性诊断（可用 / 组件缺失 / 虚拟化层未运行，各给针对性指引） ----
# 引导优先（ISSUE-006 P1）：把"缺什么"诊断出来并给可复制命令；自动安装（P2）明确不做，防止无人值守被 UAC 卡死
$wslOk = $false
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $null = & wsl.exe --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $wslOk = $true
    } else {
        # Win10 老版内置 WSL 不支持 --version（--status 可用即视为可用，另提示升级）
        $null = & wsl.exe --status 2>&1
        if ($LASTEXITCODE -eq 0) {
            $wslOk = $true
            Write-Host '[info] 检测到较旧版本 WSL（无 --version 支持），仍可运行；建议在管理员 PowerShell 执行 wsl --update 升级' -ForegroundColor DarkCyan
        }
    }
}
if (-not $wslOk) {
    Write-Host '[FAIL] 未检测到可用的 WSL2 —— 诊断：' -ForegroundColor Red
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        Write-Host ("  · Windows build {0} 低于 19041 —— 本项目要求 Win10 19041+ / Win11，请先完成 Windows 更新" -f $build) -ForegroundColor Yellow
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Host '  · wsl.exe 不存在 —— WSL 组件未安装（多数干净 Win10/11 的默认状态）' -ForegroundColor Yellow
    }
    $hyper = $false
    try { $hyper = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { }
    if ($hyper) {
        Write-Host '  · hypervisor 已运行 —— BIOS 虚拟化没问题，问题在 WSL 组件本身（未装 / 损坏 / 过旧）' -ForegroundColor Yellow
    } else {
        Write-Host '  · hypervisor 未运行 —— 常见原因按概率排序（先装 WSL，装完重启仍失败再按 b/c 处理）:' -ForegroundColor Yellow
        Write-Host '      a. WSL 尚未安装 —— 此时 hypervisor 本就不会运行，属正常，先按下面指引安装'
        Write-Host '      b. BIOS 未开虚拟化 —— 进 BIOS/UEFI 开启 Intel VT-x / AMD-V (SVM)'
        Write-Host '      c. hypervisor 启动被关（曾为 VirtualBox/游戏反作弊关闭）—— 管理员 PowerShell 执行: bcdedit /set hypervisorlaunchtype auto，然后重启'
    }
    Write-Host ''
    Write-Host '  修复指引:' -ForegroundColor Cyan
    Write-Host '    1. 开始菜单右键 → 「终端(管理员)」或「Windows PowerShell(管理员)」'
    Write-Host '    2. 执行:  wsl --install --no-distribution    （免装默认 Ubuntu——本项目用不上它）'
    Write-Host '       若提示不识别参数，改执行:  wsl --install    （会额外装一个默认 Ubuntu，可忽略）'
    Write-Host '    3. 重启电脑'
    Write-Host '    4. 重新双击 start-sandbox.cmd'
    Write-Host '    注: 安装需联网下载微软官方组件；企业策略可能禁用虚拟化（需联系 IT）。装完 wsl 仍不可用时先试: wsl --update' -ForegroundColor DarkGray
    PauseAtEnd; exit 1
}

# ---- 版本选择 ----
if ($Version) {
    if ($ids -notcontains $Version) {
        Write-Host "[FAIL] 不支持的版本 '$Version'。可用: $($ids -join ', ')（或运行 -ListVersions 查看）" -ForegroundColor Red
        PauseAtEnd; exit 1
    }
} elseif ($SkipShell) {
    $Version = Get-LastVersion $Manifest
} else {
    $Version = Select-VersionMenu $Manifest
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
[IO.File]::WriteAllText((Join-Path $LogDir 'last-version.txt'), $Version, (New-Object System.Text.UTF8Encoding($false)))

# ---- 档案（profile）选择：目标云基线，apt 源在启动期对齐（母版始终出厂官方源） ----
$profIds = @($Manifest.profiles | ForEach-Object { $_.id })
if ($Profile) {
    if ($profIds -notcontains $Profile) {
        Write-Host "[FAIL] 不支持的新机档案 '$Profile'。可用: $($profIds -join ', ')（或运行 -ListVersions 查看）" -ForegroundColor Red
        PauseAtEnd; exit 1
    }
} elseif ($SkipShell) {
    $Profile = Get-LastProfile $Manifest
} else {
    $Profile = Select-ProfileMenu $Manifest
}
$Prof = @($Manifest.profiles | Where-Object { $_.id -eq $Profile })[0]
[IO.File]::WriteAllText((Join-Path $LogDir 'last-profile.txt'), $Profile, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('新机档案: {0}（apt 源启动期对齐 → {1}）' -f $Prof.id, $Prof.mirror) -ForegroundColor DarkCyan

Write-Host '[1/6] 环境检查...（WSL OK）'

Write-Host '[2/6] 清理上次残留...'
if ((Test-Path $InstanceDir) -or (Test-Distro $DistroName)) {
    Write-Host '     [提示] 检测到上次未清理的残留（上次多半是直接关了窗口而不是输 exit）——本次清除' -ForegroundColor Yellow
}
if (-not (Cleanup)) { CleanupReport $false; PauseAtEnd; exit 1 }

Write-Host ('[3/6] 母版就绪检查（{0}）...' -f $Version)
Ensure-BaseTar $Version $Manifest

Write-Host '[4/6] 导入全新实例（每次都是出厂状态）...'
$impOut = @(& wsl --import $DistroName $InstanceDir (Join-Path $Root ('base\base-{0}.tar' -f $Version)) --version 2 2>&1 | ForEach-Object { ("$_" -replace "`0", '') })
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] wsl --import 失败 (exit=$LASTEXITCODE)" -ForegroundColor Red
    $impOut | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    if (-not (Cleanup)) { CleanupReport $false }; PauseAtEnd; exit 1
}

# ---- [5/6] 身份决策 + 注入 + 验证 ----
$useIdentity = $false
$token = ''
if (-not $NoIdentity -and (Test-Path $TokenFile)) {
    $raw = @(Get-Content -LiteralPath $TokenFile -Encoding UTF8 |
             ForEach-Object { $_.Trim() } |
             Where-Object { ($_ -ne '') -and (-not $_.StartsWith('#')) })
    if ($raw.Count -gt 0) { $token = $raw[0].Trim("`r", "`n", ' ', "`t", '"', "'") }
}
if ($NoIdentity -and (Test-Path $TokenFile)) {
    Write-Host '[info] -NoIdentity：忽略 token.txt，强制纯净模式' -ForegroundColor DarkCyan
}
if ($token -ne '') {
    if ($token -like '*REPLACE_ME*') {
        Write-Host '[FAIL] token.txt 还是占位符没替换（或改名 token.example.txt 放弃身份模式）' -ForegroundColor Red
        if (-not (Cleanup)) { CleanupReport $false }; PauseAtEnd; exit 1
    }
    if ($token -notmatch '^[A-Za-z0-9_\-]+$') {
        Write-Host '[FAIL] token 含非法字符（混入空格/引号/换行？）' -ForegroundColor Red
        if (-not (Cleanup)) { CleanupReport $false }; PauseAtEnd; exit 1
    }
    $useIdentity = $true
}
if (-not $useIdentity) {
    Write-Host '纯净模式：无任何凭据进入沙箱（如需 GitHub 身份：把 token.example.txt 复制为 token.txt 并填入你的 PAT）' -ForegroundColor DarkCyan
}

Write-Host '[5/6] 初始化 + 验证...'
$env:SB_MIRROR = $Prof.mirror
$env:SB_PROFILE = $Prof.id
$env:SB_ALIGN = @('0', '1')[[int][bool]$Prof.alignSources]
if ($useIdentity) {
    $env:GHTOKEN = $token
    $env:WSLENV = 'SB_MIRROR/u:SB_PROFILE/u:SB_ALIGN/u:GHTOKEN/u'
} else {
    $env:WSLENV = 'SB_MIRROR/u:SB_PROFILE/u:SB_ALIGN/u'
}
$token = ''

$scriptText = Get-Content -LiteralPath $SetupSh -Raw -Encoding UTF8
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
$inner = "tr -d '\r' | base64 -d | bash"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$teePath = Join-Path $LogDir ('setup-{0}-{1}.txt' -f $Version, $stamp)
$out = $b64 | & wsl -d $DistroName -u root -- bash -c $inner 2>&1
$strOut = @($out | ForEach-Object { "$_" })
$strOut | Tee-Object -FilePath $teePath | ForEach-Object {
    $s = "$_"
    if ($s -like 'PASS*') { Write-Host $s -ForegroundColor Green }
    elseif ($s -like 'FAIL*') { Write-Host $s -ForegroundColor Red }
    elseif ($s -eq '' -or $s -like '===*') { Write-Host $s }
    else { Write-Host $s -ForegroundColor DarkGray }
}
$status = 'FAIL'
$st = @($strOut | Where-Object { $_ -like 'STATUS*' })
if ($st.Count -gt 0 -and $st[-1] -like "STATUS`tOK*") { $status = 'OK' }
$modeLine = 'pure'
if ($useIdentity) { $modeLine = 'identity' }
$resultLines = @(("status=$status"), ("version=$Version"), ("profile=$Profile"), ("mode=$modeLine"), ("time=" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) +
               @($strOut | Where-Object { $_ -notlike 'STATUS*' })
[IO.File]::WriteAllLines((Join-Path $LogDir 'result-latest.txt'), $resultLines, (New-Object System.Text.UTF8Encoding($false)))

if ($status -ne 'OK') {
    Write-Host ''
    Write-Host '初始化存在失败项（详情见上与 logs\result-latest.txt）' -ForegroundColor Yellow
    if ($SkipShell -or $Force) {
        $cl = Cleanup; CleanupReport $cl
        if ($SkipShell) { Write-Host '(-SkipShell) 已清理并退出'; exit 1 }
        PauseAtEnd; exit 1
    }
    $ans = Read-Host '仍要进入沙箱？输入 y 回车，其他任意键放弃并清理'
    if ($ans -ne 'y') { $cl = Cleanup; CleanupReport $cl; PauseAtEnd; exit 1 }
}

# ---- [6/6] 进入沙箱或收尾 ----
if (-not $SkipShell) {
    Write-Host ''
    Write-Host ('[6/6] 进入沙箱（Ubuntu {0} · {1} · root）—— 退出 shell 即自动销毁全部状态' -f $Version, $Profile) -ForegroundColor Cyan
    if ($useIdentity) {
        Write-Host '      [身份模式] token 已注入：apt install git 后即可直接 clone 私有仓库（凭据随销毁消失）' -ForegroundColor DarkCyan
        Write-Host '      只在沙箱里跑你信任的代码——任何 guest 内程序都能读到这枚 token' -ForegroundColor DarkYellow
    }
    Write-Host '      退出方式只有一种：在沙箱里输 exit（点窗口 X 会让清理代码没机会执行，留下约 2GB 残留）' -ForegroundColor DarkGray
    $cl = $false
    try {
        & wsl -d $DistroName -u root
    } finally {
        Write-Host ''
        Write-Host '[清理] 销毁沙箱...' -ForegroundColor Cyan
        $cl = Cleanup
    }
    CleanupReport $cl
    if (-not $cl) { PauseAtEnd; exit 1 }
    PauseAtEnd
    exit 0
} else {
    $cl = Cleanup
    if (-not $cl) { CleanupReport $false; Write-Host '(-SkipShell) 清理未完成'; exit 1 }
    Write-Host ('(-SkipShell) 验证完成（{0}），沙箱已清理' -f $Version) -ForegroundColor Green
    exit 0
}
