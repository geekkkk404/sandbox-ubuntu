# setup.sh —— 沙箱 guest 内执行（由 start-sandbox.ps1 经 base64 送入 stdin）
# 输入: SB_PROFILE（新机档案 id）/ SB_ALIGN（1=启动期把 apt 源对齐到 SB_MIRROR，0=保持官方源）/ SB_MIRROR（档案的源，也用于可达性检查）/ SB_LANG（zh/en，缺省 zh）/ GHTOKEN（可选）
# 输出协议: PASS\t名称\t详情 | FAIL\t名称\t详情 | INFO\t详情 | STATUS\tOK/FAIL\t失败数
#   协议键（名称列）恒为英文稳定键（identity/source-align/apt-mirror/...），不随界面语言漂移——机器可读契约（ISSUE-008）
# 铁律: token 绝不打印到任何输出；没有 token = 纯净模式（合法路径，不是错误）
FAILED=0
step()  { if [ "$1" = "OK" ]; then printf 'PASS\t%s\t%s\n' "$2" "$3"; else FAILED=$((FAILED+1)); printf 'FAIL\t%s\t%s\n' "$2" "$3"; fi; }
info()  { printf 'INFO\t%s\n' "$1"; }
finish() { if [ "$FAILED" -eq 0 ]; then printf 'STATUS\tOK\n'; else printf 'STATUS\tFAIL\t%s\n' "$FAILED"; fi; exit "${1:-0}"; }

# ---- 界面语言（ISSUE-008）：SB_LANG=zh/en（宿主 start-sandbox.ps1 检测后经 WSLENV 传入；直跑缺省 zh） ----
LANG_SEL="${SB_LANG:-}"
if [ "$LANG_SEL" != "en" ] && [ "$LANG_SEL" != "zh" ]; then LANG_SEL=zh; fi
# m <键> [参数...] —— 人读文案（检查项名一律用英文协议键，不经 m）
m() {
  local k="$1"; shift
  if [ "$LANG_SEL" = "en" ]; then
    case "$k" in
      banner)      printf '=== sandbox-ubuntu · sandbox initialization ===';;
      mode)        printf 'mode=%s (pure = enter with no credentials at all | identity = GitHub identity injected)' "$1";;
      hostinfo)    printf 'hostname=%s (should be "ubuntu", not your Windows machine name)' "$1";;
      sdOk)        printf 'PID1 running, systemctl available';;
      sdFail)      printf 'not running - systemd-based drills will not work';;
      gitInfo)     printf 'git not installed - same as a fresh VPS; installing it is part of the simulation';;
      gitFail)     printf 'git present - the image deviates from the fresh-machine baseline';;
      isoDOk)      printf 'host drives not visible - isolation active';;
      isoDFail)    printf 'host drive mount found under /mnt: %s' "$1";;
      isoIOk)      printf 'cannot invoke Windows executables - interop disabled';;
      isoIFail)    printf 'can invoke Windows executables - interop not disabled';;
      profMissing) printf 'SB_PROFILE not provided';;
      mirMissing)  printf 'SB_MIRROR not provided';;
      noSrcFile)   printf 'no apt sources file exists in the base image';;
      alignOk)     printf 'apt sources -> %s (profile=%s, aligned at start, this instance only)' "$1" "$2";;
      alignFail)   printf 'target mirror not found after rewrite: %s (unexpected sources file format?)' "$1";;
      stockOk)     printf 'apt sources kept official archive.ubuntu.com (profile=%s; GCP/AWS/Azure fresh machines use stock sources)' "$1";;
      stockFail)   printf 'profile=%s but sources are not official - base image is from an old build; rebuild: build-base.ps1 -Version <id> -Force' "$1";;
      mirOk)       printf '%s reachable (prerequisite of the first apt update)' "$1";;
      mirFail)     printf 'still unreachable after 3 retries: %s (host network/proxy issue?)' "$1";;
      tokPlaceholder) printf 'token.txt still contains the placeholder';;
      tokBadFmt)   printf 'invalid characters (stray spaces/quotes/newlines?)';;
      tokPrefix)   printf 'unusual token prefix (normally github_pat_ or ghp_...)';;
      tokOk)       printf 'read, length %s (contents never echoed)' "$1";;
      credOk)      printf '/root/.git-credentials + /root/.gitconfig (usable right after apt install git)';;
      credFail)    printf 'write verification failed';;
      pyMissing)   printf 'missing (unexpected baseline)';;
      ghNetOk)     printf 'api.github.com reachable';;
      ghNetFail)   printf 'sandbox cannot reach GitHub (host network/proxy issue?)';;
      ghIdOk)      printf 'login=%s' "$1";;
      h401)        printf '401 = token invalid/expired';;
      h403)        printf '403 = insufficient permissions';;
      h404)        printf '404 = no access to that repo';;
      handOk)      printf '%s - info/refs authenticated (equivalent to a successful ls-remote)' "$1";;
      *)           printf '%s' "$k";;
    esac
  else
    case "$k" in
      banner)      printf '=== sandbox-ubuntu · 沙箱初始化 ===';;
      mode)        printf '模式=%s（pure=无任何凭据进入沙箱 | identity=已注入 GitHub 身份）' "$1";;
      hostinfo)    printf 'hostname=%s（应为 ubuntu，不应是你 Windows 的机器名）' "$1";;
      sdOk)        printf 'PID1 运行中，systemctl 可用';;
      sdFail)      printf '未运行，服务类模拟会受影响';;
      gitInfo)     printf 'git 未安装 —— 与全新VPS一致，由你模拟安装';;
      gitFail)     printf 'git 竟然存在——镜像偏离了新机基线';;
      isoDOk)      printf '宿主盘不可见 —— 隔离生效';;
      isoDFail)    printf '/mnt 下发现宿主盘挂载点: %s' "$1";;
      isoIOk)      printf '无法调用 Windows exe —— interop 已关闭';;
      isoIFail)    printf '可调用 Windows exe——interop 未生效';;
      profMissing) printf 'SB_PROFILE 未传入';;
      mirMissing)  printf 'SB_MIRROR 未传入';;
      noSrcFile)   printf '母版内不存在任何 apt 源文件';;
      alignOk)     printf 'apt 源 → %s（profile=%s，启动期对齐，仅本次实例）' "$1" "$2";;
      alignFail)   printf '改写后未见目标镜像: %s（源文件格式异常？）' "$1";;
      stockOk)     printf 'apt 源保持官方 archive.ubuntu.com（profile=%s，GCP/AWS/Azure 新机即官方源）' "$1";;
      stockFail)   printf 'profile=%s 但源非官方——母版是旧版构建，请重建: build-base.ps1 -Version <id> -Force' "$1";;
      mirOk)       printf '%s 可达（首启 apt update 的前提）' "$1";;
      mirFail)     printf '重试 3 次仍不可达: %s（宿主网络/代理问题？）' "$1";;
      tokPlaceholder) printf 'token.txt 还是占位符没替换';;
      tokBadFmt)   printf '含非法字符（混入空格/引号/换行？）';;
      tokPrefix)   printf 'token 前缀不常见（正常应为 github_pat_ 或 ghp_ 开头）';;
      tokOk)       printf '已读取 长度 %s（内容不回显）' "$1";;
      credOk)      printf '/root/.git-credentials + /root/.gitconfig（装完 git 即刻可用）';;
      credFail)    printf '写入校验失败';;
      pyMissing)   printf '缺失（基线异常）';;
      ghNetOk)     printf 'api.github.com 可达';;
      ghNetFail)   printf '沙箱无法访问 GitHub（宿主机网络/代理问题？）';;
      ghIdOk)      printf 'login=%s' "$1";;
      h401)        printf '401=token 无效/过期';;
      h403)        printf '403=权限不足';;
      h404)        printf '404=无该仓库权限';;
      handOk)      printf '%s —— info/refs 认证通过（等价 ls-remote 成功）' "$1";;
      *)           printf '%s' "$k";;
    esac
  fi
}

echo "$(m banner)"

TOKEN="${GHTOKEN:-}"
if [ -n "$TOKEN" ]; then MODE=identity; else MODE=pure; fi
info "$(m mode "$MODE")"

# ---- 环境自检（保真度证据，同时验证隔离生效） ----
if [ "$(id -u)" -eq 0 ]; then step OK 'identity' 'root'; else step FAIL 'identity' "uid=$(id -u)"; fi
info "$(m hostinfo "$(hostname 2>/dev/null || echo unknown)")"
if [ -d /run/systemd/system ]; then step OK 'systemd' "$(m sdOk)"; else step FAIL 'systemd' "$(m sdFail)"; fi
if command -v git >/dev/null 2>&1; then step FAIL 'git-baseline' "$(m gitFail)"; else info "$(m gitInfo)"; fi
STRAY=$(ls -A /mnt 2>/dev/null | grep -vE '^(wsl|wslg)$' | head -1)
if [ -n "$STRAY" ]; then step FAIL 'isolation-drives' "$(m isoDFail "$STRAY")"; else info "$(m isoDOk)"; fi
if command -v cmd.exe >/dev/null 2>&1; then step FAIL 'isolation-interop' "$(m isoIFail)"; else info "$(m isoIOk)"; fi

# ---- 新机档案（profile）：启动期把 apt 源对齐到目标云 ----
# 母版始终是出厂官方源；对齐只发生在本次实例内，随销毁消失。云内网域名不可达，一律对齐到等价公网镜像。
PROFILE="${SB_PROFILE:-}"
ALIGN="${SB_ALIGN:-0}"
MIRROR="${SB_MIRROR:-}"
if [ -z "$PROFILE" ]; then step FAIL 'profile' "$(m profMissing)"; finish 1; fi
if [ -z "$MIRROR" ]; then step FAIL 'mirror' "$(m mirMissing)"; finish 1; fi
SRC=/etc/apt/sources.list.d/ubuntu.sources
[ -f "$SRC" ] || SRC=/etc/apt/sources.list
if [ ! -f "$SRC" ]; then step FAIL 'apt-sources' "$(m noSrcFile)"; finish 1; fi
if [ "$ALIGN" = "1" ]; then
  sed -i \
    -e "s|https\?://archive.ubuntu.com/ubuntu/*|$MIRROR|g" \
    -e "s|https\?://security.ubuntu.com/ubuntu/*|$MIRROR|g" \
    "$SRC"
  if grep -Fq "$MIRROR" "$SRC"; then
    step OK 'source-align' "$(m alignOk "$MIRROR" "$PROFILE")"
  else
    step FAIL 'source-align' "$(m alignFail "$MIRROR")"
  fi
else
  if grep -Eq 'archive\.ubuntu\.com|security\.ubuntu\.com' "$SRC"; then
    step OK 'source-align' "$(m stockOk "$PROFILE")"
  else
    step FAIL 'source-align' "$(m stockFail "$PROFILE")"
  fi
fi

# ---- 网络：目标源可达（真实 VPS 的第一件事就是 apt 源可用） ----
# 冷启动实例的 DNS 有预热期（WSL NAT 链路实测：首查可慢至 7~20s，甚至当场拒绝一次后立即恢复），
# 单次检查会误判，故带退避重试 3 次；真断网时 ~66s 内仍给出红色 FAIL
if python3 - "$MIRROR" <<'PYEOF'
import sys, time, urllib.request
for attempt in range(3):
    try:
        urllib.request.urlopen(sys.argv[1], timeout=20).read(64)
        sys.exit(0)
    except Exception:
        if attempt < 2:
            time.sleep(3)
sys.exit(1)
PYEOF
then step OK 'apt-mirror' "$(m mirOk "$MIRROR")"
else step FAIL 'apt-mirror' "$(m mirFail "$MIRROR")"; finish 1
fi

# ---- 身份模式：注入 + GitHub 三段验证（纯净模式整段跳过） ----
if [ "$MODE" = "identity" ]; then
  case "$TOKEN" in
    *REPLACE_ME*) step FAIL 'token' "$(m tokPlaceholder)"; finish 1;;
  esac
  if ! printf '%s' "$TOKEN" | grep -Eq '^[A-Za-z0-9_-]+$'; then step FAIL 'token-format' "$(m tokBadFmt)"; finish 1; fi
  case "$TOKEN" in
    github_pat_*|ghp_*|gho_*|ghu_*|ghs_*|ghr_*) ;;
    *) info "$(m tokPrefix)";;
  esac
  step OK 'token' "$(m tokOk "${#TOKEN}")"

  printf 'https://x-access-token:%s@github.com\n' "$TOKEN" > /root/.git-credentials
  chmod 600 /root/.git-credentials
  printf '[credential]\n\thelper = store\n' > /root/.gitconfig
  if grep -q '^https://x-access-token:.*@github.com$' /root/.git-credentials && grep -q 'helper = store' /root/.gitconfig; then
    step OK 'credential-inject' "$(m credOk)"
  else
    step FAIL 'credential-inject' "$(m credFail)"
  fi

  if ! command -v python3 >/dev/null 2>&1; then step FAIL 'python3' "$(m pyMissing)"; finish 1; fi

  # 段1: GitHub 网络
  if python3 -c 'import urllib.request,sys
try:
    urllib.request.urlopen("https://api.github.com/rate_limit", timeout=15).read(64)
except Exception:
    sys.exit(1)'; then
    step OK 'github-network' "$(m ghNetOk)"
  else
    step FAIL 'github-network' "$(m ghNetFail)"; finish 1
  fi

  # 段2: 身份 (REST API)——python 只回结构化结果，HTTP 语义提示由 bash 侧按语言补挂
  R=$(GHTOKEN="$TOKEN" python3 -c 'import os,urllib.request,urllib.error,json,sys
req=urllib.request.Request("https://api.github.com/user",headers={"Authorization":"Bearer "+os.environ["GHTOKEN"],"User-Agent":"sandbox-ubuntu"})
try:
    d=json.load(urllib.request.urlopen(req,timeout=15))
    print("OK\t"+str(d.get("login","")))
except urllib.error.HTTPError as e:
    print("ERR\tHTTP %s"%e.code)
except Exception as e:
    print("ERR\t"+str(e)[:160])')
  KIND=${R%%$'\t'*}; DETAIL=${R#*$'\t'}
  if [ "$KIND" = "ERR" ]; then
    case "$DETAIL" in
      HTTP\ 401*) DETAIL="$DETAIL ($(m h401))";;
      HTTP\ 403*) DETAIL="$DETAIL ($(m h403))";;
      HTTP\ 404*) DETAIL="$DETAIL ($(m h404))";;
    esac
  fi
  if [ "$KIND" = "OK" ]; then step OK 'github-identity' "$(m ghIdOk "$DETAIL")"; else step FAIL 'github-identity' "$DETAIL"; finish 1; fi

  # 段3: git 协议握手（等价 git ls-remote 的第一个请求；沙箱内未装 git，用 python 直接发同样的请求）
  R=$(GHTOKEN="$TOKEN" python3 -c 'import os,urllib.request,urllib.error,json,base64,sys
tok=os.environ["GHTOKEN"]; L=os.environ.get("SB_LANG","zh")
def t(zh,en): return en if L=="en" else zh
H={"User-Agent":"sandbox-ubuntu","Authorization":"Bearer "+tok}
try:
    d=json.load(urllib.request.urlopen(urllib.request.Request("https://api.github.com/user/repos?per_page=100&visibility=private&affiliation=owner,collaborator,organization_member",headers=H),timeout=15))
    repos=[r["full_name"] for r in d[:3]]
except Exception as e:
    print("ERR\t"+t("列举私有仓库失败: ","failed to list private repos: ")+str(e)[:160]); sys.exit(0)
if not repos:
    print("ERR\t"+t("token 权限内没有任何私有仓库（创建 token 时需勾选仓库）","no private repo within the token scope (select repos when creating the token)")); sys.exit(0)
b64=base64.b64encode(("x-access-token:"+tok).encode()).decode()
last=t("未知错误","unknown error")
for repo in repos:
    req=urllib.request.Request("https://github.com/"+repo+".git/info/refs?service=git-upload-pack",headers={"User-Agent":"sandbox-ubuntu","Authorization":"Basic "+b64})
    try:
        resp=urllib.request.urlopen(req,timeout=15)
        body=resp.read(4096)
        if resp.status==200 and (b"git-upload-pack" in body or b"refs/" in body):
            print("OK\t"+repo); sys.exit(0)
        last=repo+": "+t("响应内容异常","unexpected response")
    except urllib.error.HTTPError as e:
        last=repo+": HTTP %s"%e.code
    except Exception as e:
        last=repo+": "+str(e)[:120]
print("ERR\t"+last)')
  KIND=${R%%$'\t'*}; DETAIL=${R#*$'\t'}
  if [ "$KIND" = "ERR" ]; then
    case "$DETAIL" in
      *HTTP\ 401*) DETAIL="$DETAIL ($(m h401))";;
      *HTTP\ 404*) DETAIL="$DETAIL ($(m h404))";;
    esac
  fi
  if [ "$KIND" = "OK" ]; then
    step OK 'git-handshake' "$(m handOk "$DETAIL")"
  else
    step FAIL 'git-handshake' "$DETAIL"
  fi
  unset GHTOKEN TOKEN
fi

finish
