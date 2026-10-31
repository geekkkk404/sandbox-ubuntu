# guest-build.sh —— 在母版构建实例内执行（由 build-base.ps1 做占位符替换后经 base64 传入 stdin）
# 目标：把官方 Ubuntu rootfs 对齐成「腾讯云全新 VPS」基线
# 原则：新 VPS 没有的一律不加（git 等），VPS 自带的必须有（sshd/cloud-init/systemd），apt 源对齐腾讯云公网镜像
FAILS=0
ok()  { printf 'BUILD-OK\t%s\t%s\n' "$1" "$2"; }
bad() { FAILS=$((FAILS+1)); printf 'BUILD-FAIL\t%s\t%s\n' "$1" "$2"; }
ck()  { if eval "$2" >/dev/null 2>&1; then ok "$1" "$3"; else bad "$1" "$3"; fi; }

VER="@SB_VER@"
MIRROR="@SB_MIRROR@"

echo "=== 对齐目标: Ubuntu $VER → 腾讯云全新 VPS 基线 ==="
echo '=== stock /etc/wsl.conf ==='
cat /etc/wsl.conf 2>/dev/null || echo '(不存在)'
echo '=== stock apt 源 ==='
cat /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || cat /etc/apt/sources.list 2>/dev/null || echo '(不存在)'

echo '---[1] apt 源 → 腾讯云公网镜像（自动识别 deb822 / 传统 one-line 格式） ---'
DEB822=/etc/apt/sources.list.d/ubuntu.sources
LEGACY=/etc/apt/sources.list
if [ -f "$DEB822" ]; then
  SRC=$DEB822
  STYLE=deb822
elif [ -f "$LEGACY" ]; then
  SRC=$LEGACY
  STYLE=legacy
else
  # rootfs 不带源文件：按 codename 生成传统格式（新 VPS 的兜底行为）
  . /etc/os-release
  SRC=$LEGACY
  STYLE=legacy-generated
  cat > "$LEGACY" <<EOF
deb $MIRROR $VERSION_CODENAME main restricted universe multiverse
deb $MIRROR $VERSION_CODENAME-updates main restricted universe multiverse
deb $MIRROR $VERSION_CODENAME-backports main restricted universe multiverse
deb $MIRROR $VERSION_CODENAME-security main restricted universe multiverse
EOF
fi
sed -i \
  -e "s|https\?://archive.ubuntu.com/ubuntu/*|$MIRROR|g" \
  -e "s|https\?://security.ubuntu.com/ubuntu/*|$MIRROR|g" \
  "$SRC"
ck 'apt源' "grep -Fq '$MIRROR' $SRC" "apt 源 → $MIRROR（$STYLE）"
echo '--- 生效的源（节选） ---'
grep -E '^(Types|URIs|Suites|Components|deb) ' "$SRC" 2>/dev/null | head -10

echo '---[2] apt-get update（实测镜像在构建网络内可达） ---'
AU=$(apt-get update 2>&1); ARC=$?
echo "$AU" | tail -8
if [ $ARC -eq 0 ]; then ok 'apt update' '腾讯云镜像可用'
else bad 'apt update' '失败——镜像不可达，构建中止'; echo "BUILD-DONE FAILS=$FAILS"; exit $FAILS; fi

echo '---[3] VPS 基线包（sshd/cloud-init 是新机自带，git 等一律不装） ---'
PKGS=""
command -v sshd >/dev/null 2>&1 || PKGS="$PKGS openssh-server"
command -v cloud-init >/dev/null 2>&1 || PKGS="$PKGS cloud-init"
[ -f /etc/ssl/certs/ca-certificates.crt ] || PKGS="$PKGS ca-certificates"
if [ -n "$PKGS" ]; then
  echo "需要安装:$PKGS"
  OUT=$(DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS 2>&1); RC=$?
  echo "$OUT" | tail -12
  [ $RC -eq 0 ] || bad '基线包安装' 'apt-get install 失败（见上）'
fi
ck 'openssh-server' 'command -v sshd' 'sshd（新VPS远程登录基线）'
ck 'cloud-init' 'command -v cloud-init' 'cloud-init（新VPS首启配置基线）'
ck 'ca-certificates' 'test -f /etc/ssl/certs/ca-certificates.crt' 'HTTPS 证书基线'

if command -v git >/dev/null 2>&1; then
  printf 'BUILD-INFO\tgit 出现在镜像中，按「新VPS没有的不要」原则移除\n'
  OUT=$(DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge git 2>&1); RC=$?
  echo "$OUT" | tail -6
  [ $RC -eq 0 ] || bad '移除 git' 'purge 失败（可能被其他包依赖，需人工确认）'
fi
ck 'git 未安装' '! command -v git' '与全新VPS一致（由用户模拟安装）'

echo '---[4] /etc/wsl.conf（隔离 + systemd + root 直进） ---'
HN=ubuntu
printf 'BUILD-INFO\t沙箱主机名固定为: %s（wsl.conf [network] hostname；否则 WSL 会继承你的 Windows 机器名，真实云主机名由实例元数据决定）\n' "$HN"
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
ck 'wsl.conf' 'grep -q "enabled=false" /etc/wsl.conf' 'automount/interop/appendWindowsPath 关闭 + systemd + 默认 root'
# 说明：wsl.conf 的 [boot] systemd=true 只在下次启动生效。stock noble .wsl 自带该配置（构建期 systemd 已在跑）；
# stock jammy rootfs 不带 wsl.conf（构建期未跑 systemd 属正常）。权威断言在每次沙箱启动的 setup.sh（实测 PID1）。
if [ -d /run/systemd/system ]; then
  ok 'systemd' '构建实例已在 systemd 下运行（stock 镜像自带启用）'
else
  ok 'systemd' 'wsl.conf [boot] systemd=true 已写入；构建实例本身未运行 systemd 属正常（需下次启动生效），沙箱首启时 setup.sh 会实测断言'
fi

echo '---[5] 清除构建期自动挂载残留（空挂载点目录绝不能进母版） ---'
for d in /mnt/*; do
  [ -d "$d" ] || continue
  b=$(basename "$d")
  case "$b" in wsl|wslg) continue;; esac
  if mountpoint -q "$d" 2>/dev/null; then
    umount "$d" 2>/dev/null || umount -l "$d" 2>/dev/null || true
    if mountpoint -q "$d" 2>/dev/null; then
      bad '/mnt 清理' "无法卸载 $d（懒卸载也失败，保留，绝不删除已挂载目录）"
    elif rmdir "$d" 2>/dev/null; then
      printf 'BUILD-INFO\t已卸载并移除空挂载点: %s\n' "$d"
    else
      bad '/mnt 清理' "已卸载但 $d 非空，保留（不动）"
    fi
  else
    if rmdir "$d" 2>/dev/null; then printf 'BUILD-INFO\t已移除空挂载点: %s\n' "$d"
    else bad '/mnt 清理' "无法移除 $d"; fi
  fi
done
ck '/mnt 无宿主盘挂载点' '! ls -A /mnt 2>/dev/null | grep -vE "^(wsl|wslg)$" | grep -q .' '母版不含任何 /mnt/<盘符> 目录'

echo '---[6] cloud-init 首启重置 + 恢复出厂状态 ---'
if command -v cloud-init >/dev/null 2>&1; then
  OUT=$(cloud-init clean --logs 2>&1); RC=$?
  echo "$OUT"
  if [ $RC -eq 0 ]; then ok 'cloud-init clean' '每次启动都像新机一样跑首启流程'
  else bad 'cloud-init clean' '失败（见上）'; fi
fi
apt-get clean 2>/dev/null
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 2>/dev/null
ck 'apt 出厂状态' '! ls /var/lib/apt/lists/* >/dev/null 2>&1' '包列表已清空（用户首启须 apt update，与新机一致）'

echo '---[7] 基线自检（证据留档） ---'
echo "SB_VER=$VER"
echo "whoami=$(whoami) uid=$(id -u)"
echo "python3=$(command -v python3 || echo 缺失) curl=$(command -v curl || echo 无) wget=$(command -v wget || echo 无) git=$(command -v git || echo 无)"
dpkg -l openssh-server cloud-init 2>/dev/null | awk '/^ii/{print "已装: "$2" "$3}'
echo "apt 源: $(grep -h -E '^(URIs:|deb )' $SRC 2>/dev/null | head -2)"
echo "BUILD-DONE FAILS=$FAILS"
exit $FAILS
