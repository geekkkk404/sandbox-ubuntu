# start-sandbox.ps1 —— 主入口：选版本/档案→(按需构建母版)→清理→导入全新实例→(可选身份)+验证→进入shell→退出即校验式销毁
# 参数: -Version 22.04|24.04|26.04  指定版本（缺省：交互菜单；自动化场景用上次选择或 versions.json 的 default）
#       -Profile stock|tencent|aliyun  指定新机档案（apt 源启动期对齐到目标云；缺省：菜单/上次选择/defaultProfile）
#       -Lang zh|en   界面语言（缺省按 Windows 显示语言自动检测：zh* → 中文，其余 → 英文；SB_LANG 环境变量同效）
#       -SkipShell   不开交互 shell，跑完 注入/验证/清理（自动化验证用；无人值守时自动构建缺失的母版）
#       -Force       验证失败时不询问直接放弃
#       -NoIdentity  强制纯净模式（即使 token.txt 存在也不注入）
#       -ListVersions 打印支持矩阵（版本 × 新机档案）后退出
param(
    [string]$Version,
    [string]$Profile,
    [string]$Lang,
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

# ---- 界面语言（ISSUE-008）：-Lang > SB_LANG > 自动检测（zh* → zh，其余 → en） ----
# 检测源按稳定性排序：注册表 PreferredUILanguages（= 设置里的"Windows 显示语言"，跨进程稳定）
# → 用户语言列表首项 → CurrentUICulture 兜底。
# 实测坑：多语言列表系统（如 zh-Hans-CN + en-US）在同一控制台会话里，首个 powershell 进程之后
# CurrentUICulture 可能翻转为 en-US（MUI 回退）——它只配当兜底，不配当主源。
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
$langExplicit = ($Lang -eq 'zh' -or $Lang -eq 'en')
if (-not $langExplicit) { $Lang = $env:SB_LANG }
if ($Lang -ne 'zh' -and $Lang -ne 'en') {
    $Lang = Get-UiLangAuto
    $langExplicit = $false
} else {
    $langExplicit = $true
}
$env:SB_LANG = $Lang
$NL = [string][char]10

# ---- 双语字符串表（键集必须一致，启动时自检；仅人读文案随语言，协议键 PASS/FAIL/status= 恒为英文） ----
$MSG_ZH = @{
    banner        = '=== sandbox-ubuntu · 一次性全新 Ubuntu 云机模拟器 ==='
    langInfo      = '[info] 界面语言: {0}（由 -Lang/SB_LANG 指定；缺省按 Windows 显示语言自动检测）'
    manifestMiss  = '[FAIL] 缺少支持矩阵: {0}'
    listTitle     = '支持矩阵（来源均为 Ubuntu 官方 rootfs，SHA256 固定于 versions.json）:'
    markBuilt     = '  [母版已构建]'
    markDefault   = '  [默认]'
    profListTitle = '新机档案（profile，apt 源在启动期对齐到目标云的等价公网源）:'
    verMenuTitle  = '选择 Ubuntu 版本（对应真实云厂商在售 LTS）:'
    profMenuTitle = '选择新机档案（apt 源在启动期对齐到目标云的等价公网源）:'
    menuLastUsed  = '  [{0}] {1} {2}   ← 上次使用，回车默认'
    menuItem      = '  [{0}] {1} {2}'
    menuPrompt    = '输入序号（回车 = {0}）'
    oldWsl        = '[info] 检测到较旧版本 WSL（无 --version 支持），仍可运行；建议在管理员 PowerShell 执行 wsl --update 升级'
    wsbFail       = '[FAIL] 检测到 Windows 沙箱（Windows Sandbox）—— WSL2 无法在沙箱内运行（不支持嵌套虚拟化），下面的修复指引在沙箱内不适用'
    wsbFix        = '  处理：请在物理机或完整虚拟机中运行本项目（"干净系统首启"的合法载体）:'
    wsbHyper      = '    · Hyper-V VM：宿主管理员 PowerShell 执行 Set-VMProcessor -ExposeVirtualizationExtensions $true，装好系统后在其内 wsl --install'
    wsbVmware     = '    · VMware Workstation（个人免费）：VM 设置勾选 Virtualize Intel VT-x/EPT or AMD-V/RVI'
    wsbCloud      = '    · 云端 Windows VM：选支持嵌套虚拟化的规格（如 Azure Dv3/Ev3+）；VirtualBox 仅 AMD 主机支持嵌套'
    diagTitle     = '[FAIL] 未检测到可用的 WSL2 —— 诊断：'
    diagBuild     = '  · Windows build {0} 低于 19041 —— 本项目要求 Win10 19041+ / Win11，请先完成 Windows 更新'
    diagNoCmd     = '  · wsl.exe 不存在 —— WSL 组件未安装（多数干净 Win10/11 的默认状态）'
    diagHyperYes  = '  · hypervisor 已运行 —— BIOS 虚拟化没问题，问题在 WSL 组件本身（未装 / 损坏 / 过旧）'
    diagVmHint    = '      （若你正处在虚拟机内，还需宿主为其开启嵌套虚拟化——见 README FAQ「能在 Windows 沙箱里运行吗」）'
    diagHyperNo   = '  · hypervisor 未运行 —— 常见原因按概率排序（先装 WSL，装完重启仍失败再按 b/c 处理）:'
    diagA         = '      a. WSL 尚未安装 —— 此时 hypervisor 本就不会运行，属正常，先按下面指引安装'
    diagB         = '      b. BIOS 未开虚拟化 —— 进 BIOS/UEFI 开启 Intel VT-x / AMD-V (SVM)'
    diagC         = '      c. hypervisor 启动被关（曾为 VirtualBox/游戏反作弊关闭）—— 管理员 PowerShell 执行: bcdedit /set hypervisorlaunchtype auto，然后重启'
    fixTitle      = '  修复指引:'
    fix1          = '    1. 开始菜单右键 → 「终端(管理员)」或「Windows PowerShell(管理员)」'
    fix2          = '    2. 执行:  wsl --install --no-distribution    （免装默认 Ubuntu——本项目用不上它）'
    fix2b         = '       若提示不识别参数，改执行:  wsl --install    （会额外装一个默认 Ubuntu，可忽略）'
    fix3          = '    3. 重启电脑'
    fix4          = '    4. 重新双击 start-sandbox.cmd'
    fixNote       = '    注: 安装需联网下载微软官方组件；企业策略可能禁用虚拟化（需联系 IT）。装完 wsl 仍不可用时先试: wsl --update'
    badVersion    = '[FAIL] 不支持的版本 ''{0}''。可用: {1}（或运行 -ListVersions 查看）'
    badProfile    = '[FAIL] 不支持的新机档案 ''{0}''。可用: {1}（或运行 -ListVersions 查看）'
    profLine      = '新机档案: {0}（apt 源启动期对齐 → {1}）'
    step1ok       = '[1/6] 环境检查...（WSL OK）'
    step2         = '[2/6] 清理上次残留...'
    leftover      = '     [提示] 检测到上次未清理的残留（上次多半是直接关了窗口而不是输 exit）——本次清除'
    step3         = '[3/6] 母版就绪检查（{0}）...'
    step4         = '[4/6] 导入全新实例（每次都是出厂状态）...'
    importFail    = '[FAIL] wsl --import 失败 (exit={0})'
    noIdentInfo   = '[info] -NoIdentity：忽略 token.txt，强制纯净模式'
    tokPlaceholder= '[FAIL] token.txt 还是占位符没替换（或改名 token.example.txt 放弃身份模式）'
    tokBadChars   = '[FAIL] token 含非法字符（混入空格/引号/换行？）'
    pureMode      = '纯净模式：无任何凭据进入沙箱（如需 GitHub 身份：把 token.example.txt 复制为 token.txt 并填入你的 PAT）'
    step5         = '[5/6] 初始化 + 验证...'
    failSummary   = '初始化存在失败项（详情见上与 logs\result-latest.txt）'
    skipFail      = '(-SkipShell) 已清理并退出'
    enterAnyway   = '仍要进入沙箱？输入 y 回车，其他任意键放弃并清理'
    enterSandbox  = '[6/6] 进入沙箱（Ubuntu {0} · {1} · root）—— 退出 shell 即自动销毁全部状态'
    identNote1    = '      [身份模式] token 已注入：apt install git 后即可直接 clone 私有仓库（凭据随销毁消失）'
    identNote2    = '      只在沙箱里跑你信任的代码——任何 guest 内程序都能读到这枚 token'
    exitNote      = '      退出方式只有一种：在沙箱里输 exit（点窗口 X 会让清理代码没机会执行，留下约 2GB 残留）'
    cleanupOk     = '沙箱已销毁：实例 vhdx 与注册表项已删除，并已复核确认无残留'
    cleanupWarn1  = '[警告] 清理未完成——发行版或 instance\ 仍在，磁盘没有释放！'
    cleanupWarn2  = '       处理：双击 cleanup.cmd 强制清理；下次启动也会自动重试。'
    cleanupWarn3  = '       根因：请在沙箱里输 exit 退出；直接点窗口 X 会让清理代码根本没机会执行。'
    pauseHint     = '按 Enter 关闭窗口'
    destroying    = '[清理] 销毁沙箱...'
    skipUnclean   = '(-SkipShell) 清理未完成'
    skipDone      = '(-SkipShell) 验证完成（{0}），沙箱已清理'
    buildAuto     = '[info] 版本 {0} 未构建母版，-SkipShell 自动构建（首次需联网下载官方 rootfs）...'
    buildHint     = '[提示] 版本 {0} 尚未构建母版（首次需联网下载官方 rootfs 并构建，约几分钟）'
    buildAsk      = '现在构建? [y/N]'
    buildCancel   = '已取消。可先单独构建: powershell -NoProfile -ExecutionPolicy Bypass -File build-base.ps1 -Version <id>'
    buildFail     = '[FAIL] 母版构建失败，无法继续'
    shaMissing    = '[FAIL] 缺少母版校验文件 {0} —— 请重跑 build-base.ps1 -Version {1} 生成'
    shaChecking   = '校验母版完整性（约几秒）...'
    shaMismatch   = '[FAIL] 母版 SHA256 不匹配（损坏或被改动）{0}  期望 {1}{0}  实际 {2}{0}  处理: powershell -File build-base.ps1 -Version {3} -Force 重建'
    shaOk         = '母版完整性 OK ({0}...)'
}
$MSG_EN = @{
    banner        = '=== sandbox-ubuntu · Disposable fresh-Ubuntu cloud-VM simulator ==='
    langInfo      = '[info] UI language: {0} (set via -Lang/SB_LANG; default auto-detects the Windows display language)'
    manifestMiss  = '[FAIL] Missing support matrix: {0}'
    listTitle     = 'Support matrix (all from official Ubuntu rootfs, SHA256 pinned in versions.json):'
    markBuilt     = '  [base built]'
    markDefault   = '  [default]'
    profListTitle = 'Machine profiles (apt sources aligned to the target cloud at sandbox start):'
    verMenuTitle  = 'Choose an Ubuntu version (the LTS lines cloud vendors actually sell):'
    profMenuTitle = 'Choose a machine profile (apt sources aligned to the target cloud at sandbox start):'
    menuLastUsed  = '  [{0}] {1} {2}   <- last used, Enter = default'
    menuItem      = '  [{0}] {1} {2}'
    menuPrompt    = 'Enter a number (Enter = {0})'
    oldWsl        = '[info] Older WSL detected (no --version support) but usable; consider running "wsl --update" in an admin PowerShell'
    wsbFail       = '[FAIL] Windows Sandbox detected - WSL2 cannot run inside it (no nested virtualization); the fix guide below does not apply here'
    wsbFix        = '  Fix: run this project on a physical machine or a full VM (valid hosts for a clean first-boot experience):'
    wsbHyper      = '    · Hyper-V VM: on the host run Set-VMProcessor -ExposeVirtualizationExtensions $true (admin), install the guest OS, then wsl --install inside it'
    wsbVmware     = '    · VMware Workstation (free for personal use): enable "Virtualize Intel VT-x/EPT or AMD-V/RVI" in the VM settings'
    wsbCloud      = '    · Cloud Windows VM: pick a nested-virtualization size (e.g. Azure Dv3/Ev3+); VirtualBox supports nesting on AMD hosts only'
    diagTitle     = '[FAIL] No usable WSL2 detected - diagnosis:'
    diagBuild     = '  · Windows build {0} < 19041 - this project requires Win10 19041+ / Win11; run Windows Update first'
    diagNoCmd     = '  · wsl.exe not found - the WSL component is not installed (the default state on most clean Win10/11)'
    diagHyperYes  = '  · hypervisor is running - BIOS virtualization is fine; the problem is the WSL component itself (missing / broken / outdated)'
    diagVmHint    = '      (If you are inside a VM, the host must expose nested virtualization to it - see the README FAQ "Can I run it inside Windows Sandbox?")'
    diagHyperNo   = '  · hypervisor not running - likely causes, by probability (install WSL first; if it still fails after reboot, try b/c):'
    diagA         = '      a. WSL not installed yet - the hypervisor would not run anyway; that is normal, install first (guide below)'
    diagB         = '      b. Virtualization disabled in BIOS - enter BIOS/UEFI and enable Intel VT-x / AMD-V (SVM)'
    diagC         = '      c. Hypervisor launch disabled (e.g. for VirtualBox/anti-cheat) - admin PowerShell: bcdedit /set hypervisorlaunchtype auto, then reboot'
    fixTitle      = '  Fix guide:'
    fix1          = '    1. Right-click the Start menu -> "Terminal (Admin)" or "Windows PowerShell (Admin)"'
    fix2          = '    2. Run:  wsl --install --no-distribution    (skips the default Ubuntu - this project does not use it)'
    fix2b         = '       If the parameter is not recognized, run:  wsl --install    (also installs a default Ubuntu; safe to ignore)'
    fix3          = '    3. Reboot'
    fix4          = '    4. Double-click start-sandbox.cmd again'
    fixNote       = '    Note: the install downloads official Microsoft components (internet required); corporate policy may block virtualization (contact IT). If wsl still fails afterwards, try: wsl --update'
    badVersion    = '[FAIL] Unsupported version ''{0}''. Available: {1} (or run -ListVersions)'
    badProfile    = '[FAIL] Unsupported machine profile ''{0}''. Available: {1} (or run -ListVersions)'
    profLine      = 'Machine profile: {0} (apt sources aligned at start -> {1})'
    step1ok       = '[1/6] Environment check... (WSL OK)'
    step2         = '[2/6] Cleaning up leftovers from the last run...'
    leftover      = '     [hint] Leftover from the last run detected (the window was probably closed with X instead of typing exit) - cleaning now'
    step3         = '[3/6] Base image readiness ({0})...'
    step4         = '[4/6] Importing a fresh instance (factory state every time)...'
    importFail    = '[FAIL] wsl --import failed (exit={0})'
    noIdentInfo   = '[info] -NoIdentity: ignoring token.txt, forcing clean mode'
    tokPlaceholder= '[FAIL] token.txt still contains the placeholder (or rename token.example.txt to opt out of identity mode)'
    tokBadChars   = '[FAIL] token contains invalid characters (stray spaces/quotes/newlines?)'
    pureMode      = 'Clean mode: entering the sandbox with no credentials at all (for GitHub identity: copy token.example.txt to token.txt and paste your PAT)'
    step5         = '[5/6] Initialize + verify...'
    failSummary   = 'Initialization had failures (details above and in logs\result-latest.txt)'
    skipFail      = '(-SkipShell) cleaned up and exited'
    enterAnyway   = 'Enter the sandbox anyway? Type y and press Enter; anything else cleans up and exits'
    enterSandbox  = '[6/6] Entering the sandbox (Ubuntu {0} · {1} · root) - exiting the shell destroys all state, verified'
    identNote1    = '      [identity mode] token injected: after "apt install git" you can clone private repos directly (credentials die with the instance)'
    identNote2    = '      Only run code you trust inside the sandbox - any program in the guest can read this token'
    exitNote      = '      The only correct exit is typing exit inside the sandbox (closing the window skips cleanup and leaves ~2GB behind)'
    cleanupOk     = 'Sandbox destroyed: instance vhdx and registry entry deleted; zero-leftover re-checked'
    cleanupWarn1  = '[WARN] Cleanup incomplete - the distro or instance\ still exists, disk not released!'
    cleanupWarn2  = '       Fix: double-click cleanup.cmd to force cleanup; the next start retries automatically.'
    cleanupWarn3  = '       Root cause: exit the sandbox by typing exit; clicking the window X never gives the cleanup code a chance to run.'
    pauseHint     = 'Press Enter to close'
    destroying    = '[cleanup] Destroying sandbox...'
    skipUnclean   = '(-SkipShell) cleanup incomplete'
    skipDone      = '(-SkipShell) verification done ({0}); sandbox cleaned up'
    buildAuto     = '[info] Version {0} has no base image; -SkipShell builds it automatically (first time downloads the official rootfs)...'
    buildHint     = '[hint] Version {0} has no base image yet (first time downloads the official rootfs and builds; a few minutes)'
    buildAsk      = 'Build the base image now? [y/N]'
    buildCancel   = 'Cancelled. You can build separately first: powershell -NoProfile -ExecutionPolicy Bypass -File build-base.ps1 -Version <id>'
    buildFail     = '[FAIL] Base image build failed; cannot continue'
    shaMissing    = '[FAIL] Missing base checksum file {0} - rerun build-base.ps1 -Version {1} to generate it'
    shaChecking   = 'Verifying base image integrity (a few seconds)...'
    shaMismatch   = '[FAIL] Base image SHA256 mismatch (corrupted or modified){0}  expected {1}{0}  actual {2}{0}  fix: powershell -File build-base.ps1 -Version {3} -Force'
    shaOk         = 'Base image integrity OK ({0}...)'
}
if ((Compare-Object @($MSG_ZH.Keys) @($MSG_EN.Keys)).Count -ne 0) {
    Write-Host '[FAIL] i18n string table key mismatch (development error)' -ForegroundColor Red
    exit 1
}
$MSG = $MSG_ZH; if ($Lang -eq 'en') { $MSG = $MSG_EN }
if ($langExplicit) { Write-Host ($MSG['langInfo'] -f $Lang) -ForegroundColor DarkCyan }

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
        Write-Host $MSG['cleanupOk'] -ForegroundColor Green
    } else {
        Write-Host $MSG['cleanupWarn1'] -ForegroundColor Red
        Write-Host $MSG['cleanupWarn2'] -ForegroundColor Yellow
        Write-Host $MSG['cleanupWarn3'] -ForegroundColor Yellow
    }
}
function PauseAtEnd {
    if (-not $SkipShell) { try { [void](Read-Host $MSG['pauseHint']) } catch { } }
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
    Write-Host $MSG['verMenuTitle'] -ForegroundColor Cyan
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $e = @($Manifest.versions | Where-Object { $_.id -eq $ids[$i] })[0]
        if ($ids[$i] -eq $default) {
            Write-Host ($MSG['menuLastUsed'] -f ($i + 1), $e.id, $e.name) -ForegroundColor Green
        } else {
            Write-Host ($MSG['menuItem'] -f ($i + 1), $e.id, $e.name) -ForegroundColor Gray
        }
    }
    $ans = Read-Host ($MSG['menuPrompt'] -f $default)
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
    Write-Host $MSG['profMenuTitle'] -ForegroundColor Cyan
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $e = @($Manifest.profiles | Where-Object { $_.id -eq $ids[$i] })[0]
        $nm = $e.name; if ($Lang -eq 'en' -and $e.nameEn) { $nm = $e.nameEn }
        if ($ids[$i] -eq $default) {
            Write-Host ($MSG['menuLastUsed'] -f ($i + 1), $e.id, $nm) -ForegroundColor Green
        } else {
            Write-Host ($MSG['menuItem'] -f ($i + 1), $e.id, $nm) -ForegroundColor Gray
        }
    }
    $ans = Read-Host ($MSG['menuPrompt'] -f $default)
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
            Write-Host ($MSG['buildAuto'] -f $Id) -ForegroundColor Yellow
        } else {
            Write-Host ($MSG['buildHint'] -f $Id) -ForegroundColor Yellow
            $ans = Read-Host $MSG['buildAsk']
            if ($ans -ne 'y') {
                Write-Host $MSG['buildCancel'] -ForegroundColor Yellow
                exit 1
            }
        }
        & (Join-Path $Root 'build-base.ps1') -Version $Id
        if ($LASTEXITCODE -ne 0) {
            Write-Host $MSG['buildFail'] -ForegroundColor Red
            exit 1
        }
    }
    # 母版完整性校验（防损坏/误改；构建产物必须带 .sha256）
    $shaFile = "$baseTar.sha256"
    if (-not (Test-Path $shaFile)) {
        Write-Host ($MSG['shaMissing'] -f $shaFile, $Id) -ForegroundColor Red
        exit 1
    }
    $expect = ((Get-Content -LiteralPath $shaFile -Encoding UTF8 | Select-Object -First 1).Trim()).Split(' ')[0].ToLower()
    Write-Host $MSG['shaChecking']
    $got = (Get-FileHash -Algorithm SHA256 $baseTar).Hash.ToLower()
    if ($got -ne $expect) {
        Write-Host ($MSG['shaMismatch'] -f $NL, $expect, $got, $Id) -ForegroundColor Red
        exit 1
    }
    Write-Host ($MSG['shaOk'] -f $got.Substring(0, 16)) -ForegroundColor Green
}

# ---- 支持矩阵 ----
if (-not (Test-Path $ManifestPath)) {
    Write-Host ($MSG['manifestMiss'] -f $ManifestPath) -ForegroundColor Red
    exit 1
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ids = @($Manifest.versions | ForEach-Object { $_.id })

if ($ListVersions) {
    Write-Host $MSG['listTitle'] -ForegroundColor Cyan
    foreach ($e in $Manifest.versions) {
        $built = Test-Path (Join-Path $Root ('base\base-{0}.tar' -f $e.id))
        $mark = ''
        if ($built) { $mark = $MSG['markBuilt'] }
        if ($e.id -eq $Manifest.default) { $mark = "$mark$($MSG['markDefault'])" }
        Write-Host ("  {0,-6} {1}{2}" -f $e.id, $e.name, $mark)
    }
    Write-Host ''
    Write-Host $MSG['profListTitle'] -ForegroundColor Cyan
    $defProf = Get-LastProfile $Manifest
    foreach ($p in $Manifest.profiles) {
        $mark = ''
        if ($p.id -eq $defProf) { $mark = $MSG['markDefault'] }
        $nm = $p.name; if ($Lang -eq 'en' -and $p.nameEn) { $nm = $p.nameEn }
        Write-Host ("  {0,-8} {1,-6} {2}{3}" -f $p.id, $p.mirror, $nm, $mark)
    }
    exit 0
}

Write-Host $MSG['banner'] -ForegroundColor Cyan

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
            Write-Host $MSG['oldWsl'] -ForegroundColor DarkCyan
        }
    }
}
if (-not $wslOk) {
    # Windows Sandbox 识别（ISSUE-007）：WSB 是宿主 Hyper-V 上的一次性 VM，不支持嵌套虚拟化，
    # WSL2 在其中结构性不可运行——通用诊断的 hypervisor 推理在此会误导，直接给针对性结论。
    # WDAGUtilityAccount 为 WSB 专用内置账户
    if ($env:USERNAME -eq 'WDAGUtilityAccount') {
        Write-Host $MSG['wsbFail'] -ForegroundColor Red
        Write-Host $MSG['wsbFix'] -ForegroundColor Yellow
        Write-Host $MSG['wsbHyper']
        Write-Host $MSG['wsbVmware']
        Write-Host $MSG['wsbCloud']
        PauseAtEnd; exit 1
    }
    Write-Host $MSG['diagTitle'] -ForegroundColor Red
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        Write-Host ($MSG['diagBuild'] -f $build) -ForegroundColor Yellow
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Host $MSG['diagNoCmd'] -ForegroundColor Yellow
    }
    $hyper = $false
    try { $hyper = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { }
    if ($hyper) {
        Write-Host $MSG['diagHyperYes'] -ForegroundColor Yellow
        Write-Host $MSG['diagVmHint']
    } else {
        Write-Host $MSG['diagHyperNo'] -ForegroundColor Yellow
        Write-Host $MSG['diagA']
        Write-Host $MSG['diagB']
        Write-Host $MSG['diagC']
    }
    Write-Host ''
    Write-Host $MSG['fixTitle'] -ForegroundColor Cyan
    Write-Host $MSG['fix1']
    Write-Host $MSG['fix2']
    Write-Host $MSG['fix2b']
    Write-Host $MSG['fix3']
    Write-Host $MSG['fix4']
    Write-Host $MSG['fixNote'] -ForegroundColor DarkGray
    PauseAtEnd; exit 1
}

# ---- 版本选择 ----
if ($Version) {
    if ($ids -notcontains $Version) {
        Write-Host ($MSG['badVersion'] -f $Version, ($ids -join ', ')) -ForegroundColor Red
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
        Write-Host ($MSG['badProfile'] -f $Profile, ($profIds -join ', ')) -ForegroundColor Red
        PauseAtEnd; exit 1
    }
} elseif ($SkipShell) {
    $Profile = Get-LastProfile $Manifest
} else {
    $Profile = Select-ProfileMenu $Manifest
}
$Prof = @($Manifest.profiles | Where-Object { $_.id -eq $Profile })[0]
[IO.File]::WriteAllText((Join-Path $LogDir 'last-profile.txt'), $Profile, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ($MSG['profLine'] -f $Prof.id, $Prof.mirror) -ForegroundColor DarkCyan

Write-Host $MSG['step1ok']

Write-Host $MSG['step2']
if ((Test-Path $InstanceDir) -or (Test-Distro $DistroName)) {
    Write-Host $MSG['leftover'] -ForegroundColor Yellow
}
if (-not (Cleanup)) { CleanupReport $false; PauseAtEnd; exit 1 }

Write-Host ($MSG['step3'] -f $Version)
Ensure-BaseTar $Version $Manifest

Write-Host $MSG['step4']
$impOut = @(& wsl --import $DistroName $InstanceDir (Join-Path $Root ('base\base-{0}.tar' -f $Version)) --version 2 2>&1 | ForEach-Object { ("$_" -replace "`0", '') })
if ($LASTEXITCODE -ne 0) {
    Write-Host ($MSG['importFail'] -f $LASTEXITCODE) -ForegroundColor Red
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
    Write-Host $MSG['noIdentInfo'] -ForegroundColor DarkCyan
}
if ($token -ne '') {
    if ($token -like '*REPLACE_ME*') {
        Write-Host $MSG['tokPlaceholder'] -ForegroundColor Red
        if (-not (Cleanup)) { CleanupReport $false }; PauseAtEnd; exit 1
    }
    if ($token -notmatch '^[A-Za-z0-9_\-]+$') {
        Write-Host $MSG['tokBadChars'] -ForegroundColor Red
        if (-not (Cleanup)) { CleanupReport $false }; PauseAtEnd; exit 1
    }
    $useIdentity = $true
}
if (-not $useIdentity) {
    Write-Host $MSG['pureMode'] -ForegroundColor DarkCyan
}

Write-Host $MSG['step5']
$env:SB_MIRROR = $Prof.mirror
$env:SB_PROFILE = $Prof.id
$env:SB_ALIGN = @('0', '1')[[int][bool]$Prof.alignSources]
if ($useIdentity) {
    $env:GHTOKEN = $token
    $env:WSLENV = 'SB_MIRROR/u:SB_PROFILE/u:SB_ALIGN/u:SB_LANG/u:GHTOKEN/u'
} else {
    $env:WSLENV = 'SB_MIRROR/u:SB_PROFILE/u:SB_ALIGN/u:SB_LANG/u'
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
    Write-Host $MSG['failSummary'] -ForegroundColor Yellow
    if ($SkipShell -or $Force) {
        $cl = Cleanup; CleanupReport $cl
        if ($SkipShell) { Write-Host $MSG['skipFail']; exit 1 }
        PauseAtEnd; exit 1
    }
    $ans = Read-Host $MSG['enterAnyway']
    if ($ans -ne 'y') { $cl = Cleanup; CleanupReport $cl; PauseAtEnd; exit 1 }
}

# ---- [6/6] 进入沙箱或收尾 ----
if (-not $SkipShell) {
    Write-Host ''
    Write-Host ($MSG['enterSandbox'] -f $Version, $Profile) -ForegroundColor Cyan
    if ($useIdentity) {
        Write-Host $MSG['identNote1'] -ForegroundColor DarkCyan
        Write-Host $MSG['identNote2'] -ForegroundColor DarkYellow
    }
    Write-Host $MSG['exitNote'] -ForegroundColor DarkGray
    $cl = $false
    try {
        & wsl -d $DistroName -u root
    } finally {
        Write-Host ''
        Write-Host $MSG['destroying'] -ForegroundColor Cyan
        $cl = Cleanup
    }
    CleanupReport $cl
    if (-not $cl) { PauseAtEnd; exit 1 }
    PauseAtEnd
    exit 0
} else {
    $cl = Cleanup
    if (-not $cl) { CleanupReport $false; Write-Host $MSG['skipUnclean']; exit 1 }
    Write-Host ($MSG['skipDone'] -f $Version) -ForegroundColor Green
    exit 0
}
