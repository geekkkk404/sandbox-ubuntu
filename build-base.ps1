# build-base.ps1 —— 按版本构建「全新 VPS 基线」母版（可重复运行，自带清理）
# 母版始终保持出厂官方源（archive.ubuntu.com）；目标云的 apt 源对齐由沙箱启动期 setup.sh 按新机档案（profile）执行。
# 构建期用 versions.json build.mirror 加速 apt（国内网络），仅作用于构建实例，不进母版。
# 流程: 读 versions.json → 下载官方 rootfs → SHA256 校验 → 导入构建实例 → guest-build.sh 对齐基线（导出前还原出厂源） → 导出母版(.tar+.sha256) → 销毁构建实例
# 参数: -Version 22.04|24.04|26.04   （缺省 = versions.json 的 default）
#       -Force      不信任解压缓存（rootfs.tar），强制重建；下载缓存仅在 SHA256 校验通过时复用
#       -Mirror url 构建期 apt 加速镜像覆盖（默认取 versions.json build.mirror；海外构建可指向官方源）
#       -Lang zh|en 界面语言（缺省自动检测；SB_LANG 环境变量同效——由 start-sandbox.ps1 调用时自动传入）
param(
    [string]$Version,
    [switch]$Force,
    [string]$ManifestPath,
    [string]$Mirror,
    [string]$Lang
)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Distro = 'sandbox-base-build'

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
$NL = [string][char]10
# 把界面语言传入构建实例（guest-build.sh 的 BUILD-INFO/详情文案随语言；协议键恒英文）
$env:WSLENV = 'SB_LANG/u'

# ---- 双语字符串表（键集必须一致，启动时自检） ----
$MSG_ZH = @{
    manifestMiss = '[FAIL] 缺少支持矩阵: {0}'
    noVersion    = '[FAIL] versions.json 中没有版本 ''{0}''。可用: {1}'
    noBuildMirror= '[FAIL] versions.json 缺少 build.mirror（构建期 apt 加速镜像），或未传 -Mirror'
    trySource    = '尝试源 {0}/{1}（第 {2} 次）: {3}'
    resumeNote   = '  （断点续传，从上次中断处继续）'
    shaWarn      = '[WARN] 该源下载完成但 SHA256 不匹配，删除残留，换下一个源'
    rangeWarn    = '[WARN] 该源不支持断点续传，清空残留后重试'
    srcFail      = '[WARN] 该源不可用或速度过低 (curl exit={0})，换下一个源'
    fallbackNote = '镜像未命中，对官方源做不限速兜底（支持续传）: {0}'
    allFailed    = '所有下载源均失败或校验不通过'
    step1        = '=== [1/6] 获取官方 rootfs: {0} ({1}) ==='
    cacheOk      = '缓存校验通过，跳过下载: {0}'
    cacheBad     = '[WARN] 本地缓存文件校验失败（下载不完整或已损坏），将重新下载'
    step2        = '=== [2/6] SHA256 校验 ==='
    shaFail      = '校验失败{0}  期望 {1}{0}  实际 {2}'
    step3        = '=== [3/6] 识别格式并解压为 tar ==='
    unzipped     = '已解压过，跳过'
    fmtGzip      = '格式: gzip → 解压为 tar'
    gunzipped    = '解压完成: {0} MB'
    zstdDie      = 'rootfs 是 zstd 压缩：新版 WSL 可直接 wsl --install --from-file <文件>，或转换后再试'
    fmtTar       = '格式: plain tar（未压缩），直接使用'
    unknownFmt   = '未知格式 magic={0}'
    step4        = '=== [4/6] 导入构建实例 ==='
    importFail   = 'wsl --import 失败 (exit={0})'
    step5        = '=== [5/6] 基线构建（构建期镜像加速/sshd/cloud-init/wsl.conf/cloud-init clean；导出前还原出厂官方源） ==='
    buildInFail  = '构建实例内失败 (exit={0})，日志: {1}'
    step6        = '=== [6/6] 导出母版并销毁构建实例 ==='
    exportFail   = 'wsl --export 失败 (exit={0})'
    done         = '=== 母版完成: {0} ({1} MB) ==='
    nextStep     = '    下一步: 双击 start-sandbox.cmd（或在 start-sandbox.ps1 用 -Version 选择版本）'
}
$MSG_EN = @{
    manifestMiss = '[FAIL] Missing support matrix: {0}'
    noVersion    = '[FAIL] No version ''{0}'' in versions.json. Available: {1}'
    noBuildMirror= '[FAIL] versions.json lacks build.mirror (build-time apt accelerator) and no -Mirror was given'
    trySource    = 'Trying source {0}/{1} (attempt {2}): {3}'
    resumeNote   = '  (resuming from where the last attempt stopped)'
    shaWarn      = '[WARN] Source finished but SHA256 mismatch; removing the file, trying the next source'
    rangeWarn    = '[WARN] Source does not support resume; clearing the partial file and retrying'
    srcFail      = '[WARN] Source unavailable or too slow (curl exit={0}); trying the next source'
    fallbackNote = 'No mirror hit; unlimited-speed fallback to the official source (with resume): {0}'
    allFailed    = 'All download sources failed or failed verification'
    step1        = '=== [1/6] Fetching the official rootfs: {0} ({1}) ==='
    cacheOk      = 'Cache verified, skipping download: {0}'
    cacheBad     = '[WARN] Local cache failed verification (incomplete or corrupted); downloading again'
    step2        = '=== [2/6] SHA256 verification ==='
    shaFail      = 'Verification failed{0}  expected {1}{0}  actual {2}'
    step3        = '=== [3/6] Detecting format and extracting to tar ==='
    unzipped     = 'Already extracted, skipping'
    fmtGzip      = 'Format: gzip -> extracting to tar'
    gunzipped    = 'Extraction done: {0} MB'
    zstdDie      = 'The rootfs is zstd-compressed: newer WSL can use "wsl --install --from-file <file>" directly, or convert it first'
    fmtTar       = 'Format: plain tar (uncompressed), using as-is'
    unknownFmt   = 'Unknown format, magic={0}'
    step4        = '=== [4/6] Importing the build instance ==='
    importFail   = 'wsl --import failed (exit={0})'
    step5        = '=== [5/6] Baseline build (build-time mirror / sshd / cloud-init / wsl.conf / cloud-init clean; stock sources restored before export) ==='
    buildInFail  = 'Failed inside the build instance (exit={0}), log: {1}'
    step6        = '=== [6/6] Exporting the base image and destroying the build instance ==='
    exportFail   = 'wsl --export failed (exit={0})'
    done         = '=== Base image done: {0} ({1} MB) ==='
    nextStep     = '    Next: double-click start-sandbox.cmd (or pick a version with -Version in start-sandbox.ps1)'
}
if ((Compare-Object @($MSG_ZH.Keys) @($MSG_EN.Keys)).Count -ne 0) {
    Write-Host '[FAIL] i18n string table key mismatch (development error)' -ForegroundColor Red
    exit 1
}
$MSG = $MSG_ZH; if ($Lang -eq 'en') { $MSG = $MSG_EN }

# ---- 读支持矩阵 ----
if (-not $ManifestPath) { $ManifestPath = Join-Path $Root 'versions.json' }
if (-not (Test-Path $ManifestPath)) {
    Write-Host ($MSG['manifestMiss'] -f $ManifestPath) -ForegroundColor Red
    exit 1
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Version) { $Version = $Manifest.default }
$ids = @($Manifest.versions | ForEach-Object { $_.id })
if ($ids -notcontains $Version) {
    Write-Host ($MSG['noVersion'] -f $Version, ($ids -join ', ')) -ForegroundColor Red
    exit 1
}
$Entry = @($Manifest.versions | Where-Object { $_.id -eq $Version })[0]
if (-not $Mirror) {
    if (-not ($Manifest.PSObject.Properties.Name -contains 'build') -or -not $Manifest.build.mirror) {
        Write-Host $MSG['noBuildMirror'] -ForegroundColor Red
        exit 1
    }
    $Mirror = $Manifest.build.mirror
}
$DlDir   = Join-Path $Root ('download\' + $Entry.id)
$BaseDir = Join-Path $Root 'base'
$LogDir  = Join-Path $Root 'logs'
$BuildSh = Join-Path $Root 'guest-build.sh'
$BaseTar = Join-Path $BaseDir ('base-' + $Entry.id + '.tar')
New-Item -ItemType Directory -Force -Path $DlDir, $BaseDir, $LogDir | Out-Null

function Die([string]$Msg) {
    Write-Host "[FAIL] $Msg" -ForegroundColor Red
    & wsl --unregister $Distro 2>$null | Out-Null
    exit 1
}

# 多源下载：官方源优先，镜像回退。
# 每源最多 2 次尝试，第 2 次用断点续传（挽救"前快后堵"的传输，例如 88% 处卡停）；刻意不用 curl --retry——
# 低速熔断(exit 28)会被 --retry 判为可重试错误，导致在同一慢源上反复空转（实测空转 15+ 分钟才轮到镜像）。
# 低速熔断：20 秒内低于 100KB/s 即放弃当前尝试；哈希不匹配：删除残留，换下一源。
# 全部失败后对官方源做一次不限速兜底（带 --retry 与续传，低速网络用户宁慢勿弃的最后途径）。
function Invoke-DownloadMultiSource([object]$Entry, [string]$OutFile) {
    $urls = @($Entry.url)
    if ($Entry.PSObject.Properties.Name -contains 'mirrors' -and $Entry.mirrors) { $urls += @($Entry.mirrors) }
    for ($i = 0; $i -lt $urls.Count; $i++) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Write-Host ($MSG['trySource'] -f ($i + 1), $urls.Count, $attempt, $urls[$i])
            $curlArgs = @('-L', '--connect-timeout', '20', '--speed-limit', '102400', '--speed-time', '20', '-o', $OutFile)
            if ($attempt -eq 2 -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
                Write-Host $MSG['resumeNote'] -ForegroundColor DarkGray
                $curlArgs += @('-C', '-')
            }
            $curlArgs += $urls[$i]
            & curl.exe @curlArgs
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                $got = (Get-FileHash -Algorithm SHA256 $OutFile).Hash.ToLower()
                if ($got -eq $Entry.sha256.ToLower()) { return $true }
                Write-Host $MSG['shaWarn'] -ForegroundColor Yellow
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                break
            }
            if ($code -eq 33) {
                Write-Host $MSG['rangeWarn'] -ForegroundColor Yellow
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Host ($MSG['srcFail'] -f $code) -ForegroundColor Yellow
        }
    }
    Write-Host ($MSG['fallbackNote'] -f $Entry.url) -ForegroundColor Yellow
    & curl.exe -L --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o $OutFile $Entry.url
    if ($LASTEXITCODE -ne 0) { return $false }
    $got = (Get-FileHash -Algorithm SHA256 $OutFile).Hash.ToLower()
    return ($got -eq $Entry.sha256.ToLower())
}

Write-Host ($MSG['step1'] -f $Entry.name, $Entry.id) -ForegroundColor Cyan
$WslFile = Join-Path $DlDir ($Entry.url.Split('/')[-1])
$cacheOk = $false
if (Test-Path $WslFile) {
    $cached = (Get-FileHash -Algorithm SHA256 $WslFile).Hash.ToLower()
    if ($cached -eq $Entry.sha256.ToLower()) {
        Write-Host ($MSG['cacheOk'] -f $WslFile)
        $cacheOk = $true
    } else {
        Write-Host $MSG['cacheBad'] -ForegroundColor Yellow
    }
}
if (-not $cacheOk) {
    if (-not (Invoke-DownloadMultiSource $Entry $WslFile)) {
        Die $MSG['allFailed']
    }
}

Write-Host $MSG['step2'] -ForegroundColor Cyan
$got = (Get-FileHash -Algorithm SHA256 $WslFile).Hash.ToLower()
if ($got -ne $Entry.sha256.ToLower()) {
    Die (($MSG['shaFail'] -f $NL, $Entry.sha256.ToLower(), $got))
}
Write-Host ("SHA256 OK ({0}...)" -f $got.Substring(0, 16)) -ForegroundColor Green

Write-Host $MSG['step3'] -ForegroundColor Cyan
$importFile = Join-Path $DlDir 'rootfs.tar'
if ((Test-Path $importFile) -and -not $Force) {
    Write-Host $MSG['unzipped']
} else {
    $fs = [IO.File]::OpenRead($WslFile)
    $m = New-Object byte[] 4
    [void]$fs.Read($m, 0, 4)
    $fs.Close()
    if ($m[0] -eq 0x1f -and $m[1] -eq 0x8b) {
        Write-Host $MSG['fmtGzip']
        $in = [IO.File]::OpenRead($WslFile)
        $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
        $out = [IO.File]::Create($importFile)
        $gz.CopyTo($out); $out.Close(); $gz.Close(); $in.Close()
        Write-Host ($MSG['gunzipped'] -f [math]::Round((Get-Item $importFile).Length / 1MB, 1))
    }
    elseif ($m[0] -eq 0x28 -and $m[1] -eq 0xb5 -and $m[2] -eq 0x2f -and $m[3] -eq 0xfd) {
        Die $MSG['zstdDie']
    }
    else {
        $fs = [IO.File]::OpenRead($WslFile)
        [void]$fs.Seek(257, 'Begin')
        $u = New-Object byte[] 5
        [void]$fs.Read($u, 0, 5)
        $fs.Close()
        if ([Text.Encoding]::ASCII.GetString($u) -eq 'ustar') {
            Write-Host $MSG['fmtTar']
            Copy-Item -LiteralPath $WslFile -Destination $importFile -Force
        }
        else { Die ($MSG['unknownFmt'] -f ($m -join ',')) }
    }
}

Write-Host $MSG['step4'] -ForegroundColor Cyan
& wsl --unregister $Distro 2>&1 | Out-Null
$BuildDir = Join-Path $BaseDir ('build-' + $Entry.id)
if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue }
$null = & wsl --import $Distro $BuildDir $importFile --version 2 2>&1
if ($LASTEXITCODE -ne 0) { Die ($MSG['importFail'] -f $LASTEXITCODE) }

Write-Host $MSG['step5'] -ForegroundColor Cyan
$gb = Get-Content -LiteralPath $BuildSh -Raw -Encoding UTF8
$gb = $gb.Replace('@SB_VER@', $Entry.id).Replace('@SB_MIRROR@', $Mirror)
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($gb))
$inner = "tr -d '\r' | base64 -d | bash"
$out = $b64 | & wsl -d $Distro -u root -- bash -c $inner 2>&1
$buildExit = $LASTEXITCODE
$strOut = @($out | ForEach-Object { "$_" })
$tee = Join-Path $LogDir ('build-{0}-{1:yyyyMMdd-HHmmss}.txt' -f $Entry.id, (Get-Date))
$strOut | Tee-Object -FilePath $tee | ForEach-Object {
    $s = "$_"
    if ($s -like 'BUILD-FAIL*') { Write-Host $s -ForegroundColor Red }
    elseif ($s -like 'BUILD-OK*') { Write-Host $s -ForegroundColor Green }
    else { Write-Host $s }
}
if ($buildExit -ne 0) { Die ($MSG['buildInFail'] -f $buildExit, $tee) }

Write-Host $MSG['step6'] -ForegroundColor Cyan
$null = & wsl --terminate $Distro 2>&1
Start-Sleep -Seconds 2
if (Test-Path $BaseTar) { Remove-Item $BaseTar -Force }
$expOut = @(& wsl --export $Distro $BaseTar 2>&1 | ForEach-Object { ("$_" -replace "`0", '') })
if ($LASTEXITCODE -ne 0) {
    $expOut | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Die ($MSG['exportFail'] -f $LASTEXITCODE)
}
& wsl --unregister $Distro 2>&1 | Out-Null
if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue }

$hash = (Get-FileHash -Algorithm SHA256 $BaseTar).Hash.ToLower()
$hashLine = '{0}  {1}' -f $hash, (Split-Path $BaseTar -Leaf)
[IO.File]::WriteAllText("$BaseTar.sha256", $hashLine + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$sz = [math]::Round((Get-Item $BaseTar).Length / 1MB, 1)
Write-Host ''
Write-Host ($MSG['done'] -f $BaseTar, $sz) -ForegroundColor Green
Write-Host ('    SHA256={0}' -f $hash)
Write-Host $MSG['nextStep'] -ForegroundColor Cyan
exit 0
