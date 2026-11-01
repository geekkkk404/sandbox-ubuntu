# guest-build.sh —— 在母版构建实例内执行（由 build-base.ps1 做占位符替换后经 base64 传入 stdin）
# 目标：把官方 Ubuntu rootfs 对齐成「全新 VPS」基线；母版始终保持出厂官方源
# 原则：新 VPS 没有的一律不加（git 等），VPS 自带的必须有（sshd/cloud-init/systemd）
# apt 源：构建期用加速镜像装基线包（快），导出前还原出厂官方源；目标云的源对齐由沙箱
#        启动期 setup.sh 按 profile 执行（母版每版本唯一，新增云厂商 = 纯配置，构建成本不翻倍）
# 语言：SB_LANG=zh/en（build-base.ps1 经 WSLENV 传入）。协议键（BUILD-OK/FAIL 检查项名）恒为英文，人读详情随语言（ISSUE-008）
FAILS=0
ok()  { printf -- 'BUILD-OK\t%s\t%s\n' "$1" "$2"; }
bad() { FAILS=$((FAILS+1)); printf -- 'BUILD-FAIL\t%s\t%s\n' "$1" "$2"; }
ck()  { if eval "$2" >/dev/null 2>&1; then ok "$1" "$3"; else bad "$1" "$3"; fi; }

LANG_SEL="${SB_LANG:-}"
if [ "$LANG_SEL" != "en" ] && [ "$LANG_SEL" != "zh" ]; then LANG_SEL=zh; fi
g() {
  local k="$1"; shift
  if [ "$LANG_SEL" = "en" ]; then
    case "$k" in
      banner)    printf -- '=== Ubuntu %s base image build: fresh-VPS baseline (stock sources baked in; build-time mirror for speed only) ===' "$1";;
      stockConf) printf -- '=== stock /etc/wsl.conf ===';;
      stockSrc)  printf -- '=== stock apt sources ===';;
      notFound)  printf -- '(not found)';;
      h1)        printf -- '---[1] apt sources: back up the stock official sources -> switch to the build-time mirror (auto-detects deb822 / legacy one-line) ---';;
      srcOk)     printf -- 'build-time apt sources -> %s (%s, speed-up only, never enters the base image)' "$1" "$2";;
      hSrcLive)  printf -- '--- effective sources (excerpt) ---';;
      h2)        printf -- '---[2] apt-get update (proves the mirror is reachable from the build network) ---';;
      updOk)     printf -- 'build-time mirror usable';;
      updFail)   printf -- 'failed - mirror unreachable, build aborted';;
      h3)        printf -- '---[3] VPS baseline packages (sshd/cloud-init come with a fresh machine; git etc. are never installed) ---';;
      willInstall) printf -- 'to install:%s' "$1";;
      instFail)  printf -- 'apt-get install failed (see above)';;
      sshdOk)    printf -- 'sshd (remote-login baseline of a fresh VPS)';;
      cloutOk)   printf -- 'cloud-init (first-boot configuration baseline of a fresh VPS)';;
      caOk)      printf -- 'HTTPS certificate baseline';;
      gitPurge)  printf -- 'git appeared in the image; removing it per the "fresh VPS does not have it" rule';;
      gitPurgeFail) printf -- 'purge failed (possibly depended on by other packages; needs manual review)';;
      gitAbsent) printf -- 'same as a fresh VPS (installing it is part of the user simulation)';;
      h4)        printf -- '---[4] /etc/wsl.conf (isolation + systemd + root login) ---';;
      hostInfo)  printf -- 'sandbox hostname fixed to: %s (wsl.conf [network] hostname; otherwise WSL inherits your Windows machine name, while a real cloud hostname comes from instance metadata)' "$1";;
      confOk)    printf -- 'automount/interop/appendWindowsPath disabled + systemd + default root';;
      sdLive)    printf -- 'build instance already running under systemd (stock image ships with it enabled)';;
      sdConf)    printf -- 'wsl.conf [boot] systemd=true written; the build instance itself not running systemd is expected (takes effect next boot) - setup.sh asserts the real PID1 at every sandbox start';;
      h5)        printf -- '---[5] Clearing build-time automount leftovers (empty mountpoint directories must never enter the base image) ---';;
      mntFailUm) printf -- 'cannot unmount %s (lazy unmount failed too; kept - never delete a mounted directory)' "$1";;
      mntRmU)    printf -- 'unmounted and removed empty mountpoint: %s' "$1";;
      mntKeep)   printf -- 'unmounted but %s is not empty, kept (untouched)' "$1";;
      mntFailRm) printf -- 'cannot remove %s' "$1";;
      mntRm)     printf -- 'removed empty mountpoint: %s' "$1";;
      mntOk)     printf -- 'base image contains no /mnt/<drive> directories';;
      h6)        printf -- '---[6] Restoring the stock official sources (the base image carries no cloud mirror; alignment happens at sandbox start per profile) ---';;
      stockBack) printf -- 'base image keeps the official sources (build-time mirror restored)';;
      stockMiss) printf -- 'backup %s missing (should never happen)' "$1";;
      hStockLive) printf -- '--- stock sources (excerpt) ---';;
      h7)        printf -- '---[7] cloud-init first-boot reset + restore factory state ---';;
      ciOk)      printf -- 'every start runs the first-boot flow like a brand-new machine';;
      ciFail)    printf -- 'failed (see above)';;
      aptClean)  printf -- 'package lists emptied (your first apt update is yours to run, same as a fresh machine)';;
      h8)        printf -- '---[8] Baseline self-check (evidence on record) ---';;
      missing)   printf -- 'missing';;
      none)      printf -- 'none';;
      installed) printf -- 'installed: %s %s' "$1" "$2";;
      baseSrc)   printf -- 'base image stock sources: %s' "$1";;
      *)         printf -- '%s' "$k";;
    esac
  else
    case "$k" in
      banner)    printf -- '=== Ubuntu %s 母版构建：新机基线（出厂官方源；构建期用镜像加速） ===' "$1";;
      stockConf) printf -- '=== stock /etc/wsl.conf ===';;
      stockSrc)  printf -- '=== stock apt 源 ===';;
      notFound)  printf -- '(不存在)';;
      h1)        printf -- '---[1] apt 源：备份出厂官方源 → 构建期换加速镜像（自动识别 deb822 / 传统 one-line 格式） ---';;
      srcOk)     printf -- '构建期 apt 源 → %s（%s，仅加速，不进母版）' "$1" "$2";;
      hSrcLive)  printf -- '--- 生效的源（节选） ---';;
      h2)        printf -- '---[2] apt-get update（实测镜像在构建网络内可达） ---';;
      updOk)     printf -- '构建期镜像可用';;
      updFail)   printf -- '失败——镜像不可达，构建中止';;
      h3)        printf -- '---[3] VPS 基线包（sshd/cloud-init 是新机自带，git 等一律不装） ---';;
      willInstall) printf -- '需要安装:%s' "$1";;
      instFail)  printf -- 'apt-get install 失败（见上）';;
      sshdOk)    printf -- 'sshd（新VPS远程登录基线）';;
      cloutOk)   printf -- 'cloud-init（新VPS首启配置基线）';;
      caOk)      printf -- 'HTTPS 证书基线';;
      gitPurge)  printf -- 'git 出现在镜像中，按「新VPS没有的不要」原则移除';;
      gitPurgeFail) printf -- 'purge 失败（可能被其他包依赖，需人工确认）';;
      gitAbsent) printf -- '与全新VPS一致（由用户模拟安装）';;
      h4)        printf -- '---[4] /etc/wsl.conf（隔离 + systemd + root 直进） ---';;
      hostInfo)  printf -- '沙箱主机名固定为: %s（wsl.conf [network] hostname；否则 WSL 会继承你的 Windows 机器名，真实云主机名由实例元数据决定）' "$1";;
      confOk)    printf -- 'automount/interop/appendWindowsPath 关闭 + systemd + 默认 root';;
      sdLive)    printf -- '构建实例已在 systemd 下运行（stock 镜像自带启用）';;
      sdConf)    printf -- 'wsl.conf [boot] systemd=true 已写入；构建实例本身未运行 systemd 属正常（需下次启动生效），沙箱首启时 setup.sh 会实测断言';;
      h5)        printf -- '---[5] 清除构建期自动挂载残留（空挂载点目录绝不能进母版） ---';;
      mntFailUm) printf -- '无法卸载 %s（懒卸载也失败，保留，绝不删除已挂载目录）' "$1";;
      mntRmU)    printf -- '已卸载并移除空挂载点: %s' "$1";;
      mntKeep)   printf -- '已卸载但 %s 非空，保留（不动）' "$1";;
      mntFailRm) printf -- '无法移除 %s' "$1";;
      mntRm)     printf -- '已移除空挂载点: %s' "$1";;
      mntOk)     printf -- '母版不含任何 /mnt/<盘符> 目录';;
      h6)        printf -- '---[6] 还原出厂官方源（母版不携带任何云镜像；对齐由沙箱启动期按 profile 执行） ---';;
      stockBack) printf -- '母版保持官方源（加速镜像已还原）';;
      stockMiss) printf -- '备份 %s 缺失（不应发生）' "$1";;
      hStockLive) printf -- '--- 出厂源（节选） ---';;
      h7)        printf -- '---[7] cloud-init 首启重置 + 恢复出厂状态 ---';;
      ciOk)      printf -- '每次启动都像新机一样跑首启流程';;
      ciFail)    printf -- '失败（见上）';;
      aptClean)  printf -- '包列表已清空（用户首启须 apt update，与新机一致）';;
      h8)        printf -- '---[8] 基线自检（证据留档） ---';;
      missing)   printf -- '缺失';;
      none)      printf -- '无';;
      installed) printf -- '已装: %s %s' "$1" "$2";;
      baseSrc)   printf -- '母版出厂源: %s' "$1";;
      *)         printf -- '%s' "$k";;
    esac
  fi
}

VER="@SB_VER@"
MIRROR="@SB_MIRROR@"

echo "$(g banner "$VER")"
echo "$(g stockConf)"
cat /etc/wsl.conf 2>/dev/null || echo "$(g notFound)"
echo "$(g stockSrc)"
cat /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || cat /etc/apt/sources.list 2>/dev/null || echo "$(g notFound)"

echo "$(g h1)"
DEB822=/etc/apt/sources.list.d/ubuntu.sources
LEGACY=/etc/apt/sources.list
if [ -f "$DEB822" ]; then
  SRC=$DEB822
  STYLE=deb822
elif [ -f "$LEGACY" ]; then
  SRC=$LEGACY
  STYLE=legacy
else
  # rootfs 不带源文件：按 codename 生成官方源（这就是母版的出厂状态）
  . /etc/os-release
  SRC=$LEGACY
  STYLE=legacy-generated
  cat > "$LEGACY" <<EOF
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $VERSION_CODENAME-security main restricted universe multiverse
EOF
fi
# 备份出厂源到 /root/（绝不能放 sources.list.d/ —— apt 会把备份当第二个源文件解析）
STOCKBAK=/root/.sb-stock-sources
cp -a "$SRC" "$STOCKBAK"
sed -i \
  -e "s|https\?://archive.ubuntu.com/ubuntu/*|$MIRROR|g" \
  -e "s|https\?://security.ubuntu.com/ubuntu/*|$MIRROR|g" \
  "$SRC"
ck 'apt-src-build' "grep -Fq '$MIRROR' $SRC" "$(g srcOk "$MIRROR" "$STYLE")"
echo "$(g hSrcLive)"
grep -E '^(Types|URIs|Suites|Components|deb) ' "$SRC" 2>/dev/null | head -10

echo "$(g h2)"
AU=$(apt-get update 2>&1); ARC=$?
echo "$AU" | tail -8
if [ $ARC -eq 0 ]; then ok 'apt update' "$(g updOk)"
else bad 'apt update' "$(g updFail)"; echo "BUILD-DONE FAILS=$FAILS"; exit $FAILS; fi

echo "$(g h3)"
PKGS=""
command -v sshd >/dev/null 2>&1 || PKGS="$PKGS openssh-server"
command -v cloud-init >/dev/null 2>&1 || PKGS="$PKGS cloud-init"
[ -f /etc/ssl/certs/ca-certificates.crt ] || PKGS="$PKGS ca-certificates"
if [ -n "$PKGS" ]; then
  echo "$(g willInstall "$PKGS")"
  OUT=$(DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS 2>&1); RC=$?
  echo "$OUT" | tail -12
  [ $RC -eq 0 ] || bad 'baseline-packages' "$(g instFail)"
fi
ck 'openssh-server' 'command -v sshd' "$(g sshdOk)"
ck 'cloud-init' 'command -v cloud-init' "$(g cloutOk)"
ck 'ca-certificates' 'test -f /etc/ssl/certs/ca-certificates.crt' "$(g caOk)"

if command -v git >/dev/null 2>&1; then
  printf -- 'BUILD-INFO\t%s\n' "$(g gitPurge)"
  OUT=$(DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge git 2>&1); RC=$?
  echo "$OUT" | tail -6
  [ $RC -eq 0 ] || bad 'git-purge' "$(g gitPurgeFail)"
fi
ck 'git-absent' '! command -v git' "$(g gitAbsent)"

echo "$(g h4)"
HN=ubuntu
printf -- 'BUILD-INFO\t%s\n' "$(g hostInfo "$HN")"
cat > /etc/wsl.conf <<EOS
[automount]
enabled=false
[interop]
enabled=false
appendWindowsPath=false
[boot]
systemd=true
[user]
default=root
[network]
hostname=$HN
EOS
ck 'wsl-conf' 'grep -q "enabled=false" /etc/wsl.conf' "$(g confOk)"
# 说明：wsl.conf 的 [boot] systemd=true 只在下次启动生效。stock noble .wsl 自带该配置（构建期 systemd 已在跑）；
# stock jammy rootfs 不带 wsl.conf（构建期未跑 systemd 属正常）。权威断言在每次沙箱启动的 setup.sh（实测 PID1）。
if [ -d /run/systemd/system ]; then
  ok 'systemd' "$(g sdLive)"
else
  ok 'systemd' "$(g sdConf)"
fi

echo "$(g h5)"
for d in /mnt/*; do
  [ -d "$d" ] || continue
  b=$(basename "$d")
  case "$b" in wsl|wslg) continue;; esac
  if mountpoint -q "$d" 2>/dev/null; then
    umount "$d" 2>/dev/null || umount -l "$d" 2>/dev/null || true
    if mountpoint -q "$d" 2>/dev/null; then
      bad 'mnt-cleanup' "$(g mntFailUm "$d")"
    elif rmdir "$d" 2>/dev/null; then
      printf -- 'BUILD-INFO\t%s\n' "$(g mntRmU "$d")"
    else
      bad 'mnt-cleanup' "$(g mntKeep "$d")"
    fi
  else
    if rmdir "$d" 2>/dev/null; then printf -- 'BUILD-INFO\t%s\n' "$(g mntRm "$d")"
    else bad 'mnt-cleanup' "$(g mntFailRm "$d")"; fi
  fi
done
ck 'mnt-clean' '! ls -A /mnt 2>/dev/null | grep -vE "^(wsl|wslg)$" | grep -q .' "$(g mntOk)"

echo "$(g h6)"
if [ -f "$STOCKBAK" ]; then
  mv -f "$STOCKBAK" "$SRC"
  ck 'base-stock-sources' "grep -Eq 'archive.ubuntu.com|security.ubuntu.com' $SRC && ! grep -Fq '$MIRROR' $SRC" "$(g stockBack)"
else
  bad 'base-stock-sources' "$(g stockMiss "$STOCKBAK")"
fi
echo "$(g hStockLive)"
grep -E '^(Types|URIs|Suites|Components|deb) ' "$SRC" 2>/dev/null | head -10

echo "$(g h7)"
if command -v cloud-init >/dev/null 2>&1; then
  OUT=$(cloud-init clean --logs 2>&1); RC=$?
  echo "$OUT"
  if [ $RC -eq 0 ]; then ok 'cloud-init clean' "$(g ciOk)"
  else bad 'cloud-init clean' "$(g ciFail)"; fi
fi
apt-get clean 2>/dev/null
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 2>/dev/null
ck 'apt-factory-state' '! ls /var/lib/apt/lists/* >/dev/null 2>&1' "$(g aptClean)"

echo "$(g h8)"
echo "SB_VER=$VER"
echo "whoami=$(whoami) uid=$(id -u)"
echo "python3=$(command -v python3 || echo "$(g missing)") curl=$(command -v curl || echo "$(g none)") wget=$(command -v wget || echo "$(g none)") git=$(command -v git || echo "$(g none)")"
dpkg -l openssh-server cloud-init 2>/dev/null | awk '/^ii/{print $2" "$3}' | while read -r pn pv; do printf -- '%s\n' "$(g installed "$pn" "$pv")"; done
echo "$(g baseSrc "$(grep -h -E '^(URIs:|deb )' $SRC 2>/dev/null | head -2)")"
echo "BUILD-DONE FAILS=$FAILS"
exit $FAILS
