# build-base.ps1 —— 按版本构建「全新 VPS 基线」母版（可重复运行，自带清理）
# 母版始终保持出厂官方源（archive.ubuntu.com）；目标云的 apt 源对齐由沙箱启动期 setup.sh 按新机档案（profile）执行。
# 构建期用 versions.json build.mirror 加速 apt（国内网络），仅作用于构建实例，不进母版。
# 流程: 读 versions.json → 下载官方 rootfs → SHA256 校验 → 导入构建实例 → guest-build.sh 对齐基线（导出前还原出厂源） → 导出母版(.tar+.sha256) → 销毁构建实例
# 参数: -Version 22.04|24.04|26.04   （缺省 = versions.json 的 default）
#       -Force      不信任解压缓存（rootfs.tar），强制重建；下载缓存仅在 SHA256 校验通过时复用
#       -Mirror url 构建期 apt 加速镜像覆盖（默认取 versions.json build.mirror；海外构建可指向官方源）
param(
    [string]$Version,
    [switch]$Force,
    [string]$ManifestPath,
    [string]$Mirror
)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Distro = 'sandbox-base-build'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---- 读支持矩阵 ----
if (-not $ManifestPath) { $ManifestPath = Join-Path $Root 'versions.json' }
if (-not (Test-Path $ManifestPath)) {
    Write-Host "[FAIL] 缺少支持矩阵: $ManifestPath" -ForegroundColor Red
    exit 1
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Version) { $Version = $Manifest.default }
$ids = @($Manifest.versions | ForEach-Object { $_.id })
if ($ids -notcontains $Version) {
    Write-Host "[FAIL] versions.json 中没有版本 '$Version'。可用: $($ids -join ', ')" -ForegroundColor Red
    exit 1
}
$Entry = @($Manifest.versions | Where-Object { $_.id -eq $Version })[0]
if (-not $Mirror) {
    if (-not ($Manifest.PSObject.Properties.Name -contains 'build') -or -not $Manifest.build.mirror) {
        Write-Host '[FAIL] versions.json 缺少 build.mirror（构建期 apt 加速镜像），或未传 -Mirror' -ForegroundColor Red
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
            Write-Host ("尝试源 {0}/{1}（第 {2} 次）: {3}" -f ($i + 1), $urls.Count, $attempt, $urls[$i])
            $curlArgs = @('-L', '--connect-timeout', '20', '--speed-limit', '102400', '--speed-time', '20', '-o', $OutFile)
            if ($attempt -eq 2 -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
                Write-Host '  （断点续传，从上次中断处继续）' -ForegroundColor DarkGray
                $curlArgs += @('-C', '-')
            }
            $curlArgs += $urls[$i]
            & curl.exe @curlArgs
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                $got = (Get-FileHash -Algorithm SHA256 $OutFile).Hash.ToLower()
                if ($got -eq $Entry.sha256.ToLower()) { return $true }
                Write-Host '[WARN] 该源下载完成但 SHA256 不匹配，删除残留，换下一个源' -ForegroundColor Yellow
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                break
            }
            if ($code -eq 33) {
                Write-Host '[WARN] 该源不支持断点续传，清空残留后重试' -ForegroundColor Yellow
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Host ("[WARN] 该源不可用或速度过低 (curl exit={0})，换下一个源" -f $code) -ForegroundColor Yellow
        }
    }
    Write-Host ("镜像未命中，对官方源做不限速兜底（支持续传）: {0}" -f $Entry.url) -ForegroundColor Yellow
    & curl.exe -L --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o $OutFile $Entry.url
    if ($LASTEXITCODE -ne 0) { return $false }
    $got = (Get-FileHash -Algorithm SHA256 $OutFile).Hash.ToLower()
    return ($got -eq $Entry.sha256.ToLower())
}

Write-Host ('=== [1/6] 获取官方 rootfs: {0} ({1}) ===' -f $Entry.name, $Entry.id) -ForegroundColor Cyan
$WslFile = Join-Path $DlDir ($Entry.url.Split('/')[-1])
$cacheOk = $false
if (Test-Path $WslFile) {
    $cached = (Get-FileHash -Algorithm SHA256 $WslFile).Hash.ToLower()
    if ($cached -eq $Entry.sha256.ToLower()) {
        Write-Host "缓存校验通过，跳过下载: $WslFile"
        $cacheOk = $true
    } else {
        Write-Host '[WARN] 本地缓存文件校验失败（下载不完整或已损坏），将重新下载' -ForegroundColor Yellow
    }
}
if (-not $cacheOk) {
    if (-not (Invoke-DownloadMultiSource $Entry $WslFile)) {
        Die '所有下载源均失败或校验不通过'
    }
}

Write-Host '=== [2/6] SHA256 校验 ===' -ForegroundColor Cyan
$got = (Get-FileHash -Algorithm SHA256 $WslFile).Hash.ToLower()
if ($got -ne $Entry.sha256.ToLower()) {
    Die ("校验失败`n  期望 " + $Entry.sha256.ToLower() + "`n  实际 " + $got)
}
Write-Host ("SHA256 OK ({0}...)" -f $got.Substring(0, 16)) -ForegroundColor Green

Write-Host '=== [3/6] 识别格式并解压为 tar ===' -ForegroundColor Cyan
$importFile = Join-Path $DlDir 'rootfs.tar'
if ((Test-Path $importFile) -and -not $Force) {
    Write-Host '已解压过，跳过'
} else {
    $fs = [IO.File]::OpenRead($WslFile)
    $m = New-Object byte[] 4
    [void]$fs.Read($m, 0, 4)
    $fs.Close()
    if ($m[0] -eq 0x1f -and $m[1] -eq 0x8b) {
        Write-Host '格式: gzip → 解压为 tar'
        $in = [IO.File]::OpenRead($WslFile)
        $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
        $out = [IO.File]::Create($importFile)
        $gz.CopyTo($out); $out.Close(); $gz.Close(); $in.Close()
        Write-Host ("解压完成: {0} MB" -f [math]::Round((Get-Item $importFile).Length / 1MB, 1))
    }
    elseif ($m[0] -eq 0x28 -and $m[1] -eq 0xb5 -and $m[2] -eq 0x2f -and $m[3] -eq 0xfd) {
        Die 'rootfs 是 zstd 压缩：新版 WSL 可直接 wsl --install --from-file <文件>，或转换后再试'
    }
    else {
        $fs = [IO.File]::OpenRead($WslFile)
        [void]$fs.Seek(257, 'Begin')
        $u = New-Object byte[] 5
        [void]$fs.Read($u, 0, 5)
        $fs.Close()
        if ([Text.Encoding]::ASCII.GetString($u) -eq 'ustar') {
            Write-Host '格式: plain tar（未压缩），直接使用'
            Copy-Item -LiteralPath $WslFile -Destination $importFile -Force
        }
        else { Die ('未知格式 magic=' + ($m -join ',')) }
    }
}

Write-Host '=== [4/6] 导入构建实例 ===' -ForegroundColor Cyan
& wsl --unregister $Distro 2>&1 | Out-Null
$BuildDir = Join-Path $BaseDir ('build-' + $Entry.id)
if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue }
$null = & wsl --import $Distro $BuildDir $importFile --version 2 2>&1
if ($LASTEXITCODE -ne 0) { Die "wsl --import 失败 (exit=$LASTEXITCODE)" }

Write-Host '=== [5/6] 基线构建（构建期镜像加速/sshd/cloud-init/wsl.conf/cloud-init clean；导出前还原出厂官方源） ===' -ForegroundColor Cyan
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
if ($buildExit -ne 0) { Die ("构建实例内失败 (exit=$buildExit)，日志: $tee") }

Write-Host '=== [6/6] 导出母版并销毁构建实例 ===' -ForegroundColor Cyan
$null = & wsl --terminate $Distro 2>&1
Start-Sleep -Seconds 2
if (Test-Path $BaseTar) { Remove-Item $BaseTar -Force }
$expOut = @(& wsl --export $Distro $BaseTar 2>&1 | ForEach-Object { ("$_" -replace "`0", '') })
if ($LASTEXITCODE -ne 0) {
    $expOut | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Die "wsl --export 失败 (exit=$LASTEXITCODE)"
}
& wsl --unregister $Distro 2>&1 | Out-Null
if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue }

$hash = (Get-FileHash -Algorithm SHA256 $BaseTar).Hash.ToLower()
$hashLine = '{0}  {1}' -f $hash, (Split-Path $BaseTar -Leaf)
[IO.File]::WriteAllText("$BaseTar.sha256", $hashLine + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$sz = [math]::Round((Get-Item $BaseTar).Length / 1MB, 1)
Write-Host ''
Write-Host ('=== 母版完成: {0} ({1} MB) ===' -f $BaseTar, $sz) -ForegroundColor Green
Write-Host ('    SHA256={0}' -f $hash)
Write-Host '    下一步: 双击 start-sandbox.cmd（或在 start-sandbox.ps1 用 -Version 选择版本）' -ForegroundColor Cyan
exit 0
