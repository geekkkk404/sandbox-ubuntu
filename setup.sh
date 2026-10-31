# setup.sh —— 沙箱 guest 内执行（由 start-sandbox.ps1 经 base64 送入 stdin）
# 输出协议: PASS\t名称\t详情 | FAIL\t名称\t详情 | INFO\t详情 | STATUS\tOK/FAIL\t失败数
# 铁律: token 绝不打印到任何输出；没有 token = 纯净模式（合法路径，不是错误）
FAILED=0
step()  { if [ "$1" = "OK" ]; then printf 'PASS\t%s\t%s\n' "$2" "$3"; else FAILED=$((FAILED+1)); printf 'FAIL\t%s\t%s\n' "$2" "$3"; fi; }
info()  { printf 'INFO\t%s\n' "$1"; }
finish() { if [ "$FAILED" -eq 0 ]; then printf 'STATUS\tOK\n'; else printf 'STATUS\tFAIL\t%s\n' "$FAILED"; fi; exit "${1:-0}"; }

echo '=== sandbox-ubuntu · 沙箱初始化 ==='

TOKEN="${GHTOKEN:-}"
if [ -n "$TOKEN" ]; then MODE=identity; else MODE=pure; fi
info "模式=$MODE（pure=无任何凭据进入沙箱 | identity=已注入 GitHub 身份）"

# ---- 环境自检（保真度证据，同时验证隔离生效） ----
if [ "$(id -u)" -eq 0 ]; then step OK '登录身份' 'root'; else step FAIL '登录身份' "uid=$(id -u)"; fi
info "hostname=$(hostname 2>/dev/null || echo 未知)（应为 ubuntu，不应是你 Windows 的机器名）"
if [ -d /run/systemd/system ]; then step OK 'systemd' 'PID1 运行中，systemctl 可用'; else step FAIL 'systemd' '未运行，服务类模拟会受影响'; fi
if command -v git >/dev/null 2>&1; then step FAIL 'git 基线' 'git 竟然存在——镜像偏离了新机基线'; else info 'git 未安装 —— 与全新VPS一致，由你模拟安装'; fi
STRAY=$(ls -A /mnt 2>/dev/null | grep -vE '^(wsl|wslg)$' | head -1)
if [ -n "$STRAY" ]; then step FAIL '隔离(盘符)' "/mnt 下发现宿主盘挂载点: $STRAY"; else info '宿主盘不可见 —— 隔离生效'; fi
if command -v cmd.exe >/dev/null 2>&1; then step FAIL '隔离(interop)' '可调用 Windows exe——interop 未生效'; else info '无法调用 Windows exe —— interop 已关闭'; fi

# ---- 网络：apt 镜像可达（真实 VPS 的第一件事就是 apt 源可用） ----
MIRROR="${SB_MIRROR:-}"
if [ -z "$MIRROR" ]; then step FAIL '镜像地址' 'SB_MIRROR 未传入'; finish 1; fi
if python3 - "$MIRROR" <<'PYEOF'
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=15).read(64)
except Exception:
    sys.exit(1)
PYEOF
then step OK 'apt 镜像' "$MIRROR 可达（首启 apt update 的前提）"
else step FAIL 'apt 镜像' "不可达: $MIRROR（宿主网络/代理问题？）"; finish 1
fi

# ---- 身份模式：注入 + GitHub 三段验证（纯净模式整段跳过） ----
if [ "$MODE" = "identity" ]; then
  case "$TOKEN" in
    *REPLACE_ME*) step FAIL 'token' 'token.txt 还是占位符没替换'; finish 1;;
  esac
  if ! printf '%s' "$TOKEN" | grep -Eq '^[A-Za-z0-9_-]+$'; then step FAIL 'token 格式' '含非法字符（混入空格/引号/换行？）'; finish 1; fi
  case "$TOKEN" in
    github_pat_*|ghp_*|gho_*|ghu_*|ghs_*|ghr_*) ;;
    *) info 'token 前缀不常见（正常应为 github_pat_ 或 ghp_ 开头）';;
  esac
  step OK 'token' "已读取 长度 ${#TOKEN}（内容不回显）"

  printf 'https://x-access-token:%s@github.com\n' "$TOKEN" > /root/.git-credentials
  chmod 600 /root/.git-credentials
  printf '[credential]\n\thelper = store\n' > /root/.gitconfig
  if grep -q '^https://x-access-token:.*@github.com$' /root/.git-credentials && grep -q 'helper = store' /root/.gitconfig; then
    step OK '凭据注入' '/root/.git-credentials + /root/.gitconfig（装完 git 即刻可用）'
  else
    step FAIL '凭据注入' '写入校验失败'
  fi

  if ! command -v python3 >/dev/null 2>&1; then step FAIL 'python3' '缺失（基线异常）'; finish 1; fi

  # 段1: GitHub 网络
  if python3 -c 'import urllib.request,sys
try:
    urllib.request.urlopen("https://api.github.com/rate_limit", timeout=15).read(64)
except Exception:
    sys.exit(1)'; then
    step OK 'GitHub 网络' 'api.github.com 可达'
  else
    step FAIL 'GitHub 网络' '沙箱无法访问 GitHub（宿主机网络/代理问题？）'; finish 1
  fi

  # 段2: 身份 (REST API)
  R=$(GHTOKEN="$TOKEN" python3 -c 'import os,urllib.request,urllib.error,json,sys
req=urllib.request.Request("https://api.github.com/user",headers={"Authorization":"Bearer "+os.environ["GHTOKEN"],"User-Agent":"sandbox-ubuntu"})
try:
    d=json.load(urllib.request.urlopen(req,timeout=15))
    print("OK\t"+str(d.get("login","")))
except urllib.error.HTTPError as e:
    print("ERR\tHTTP %s（401=token无效/过期，403=权限不足）"%e.code)
except Exception as e:
    print("ERR\t"+str(e)[:160])')
  KIND=${R%%$'\t'*}; DETAIL=${R#*$'\t'}
  if [ "$KIND" = "OK" ]; then step OK 'GitHub 身份' "login=$DETAIL"; else step FAIL 'GitHub 身份' "$DETAIL"; finish 1; fi

  # 段3: git 协议握手（等价 git ls-remote 的第一个请求；沙箱内未装 git，用 python 直接发同样的请求）
  R=$(GHTOKEN="$TOKEN" python3 -c 'import os,urllib.request,urllib.error,json,base64,sys
tok=os.environ["GHTOKEN"]
H={"User-Agent":"sandbox-ubuntu","Authorization":"Bearer "+tok}
try:
    d=json.load(urllib.request.urlopen(urllib.request.Request("https://api.github.com/user/repos?per_page=100&visibility=private&affiliation=owner,collaborator,organization_member",headers=H),timeout=15))
    repos=[r["full_name"] for r in d[:3]]
except Exception as e:
    print("ERR\t列举私有仓库失败: "+str(e)[:160]); sys.exit(0)
if not repos:
    print("ERR\ttoken 权限内没有任何私有仓库（创建 token 时需勾选仓库）"); sys.exit(0)
b64=base64.b64encode(("x-access-token:"+tok).encode()).decode()
last="未知错误"
for repo in repos:
    req=urllib.request.Request("https://github.com/"+repo+".git/info/refs?service=git-upload-pack",headers={"User-Agent":"sandbox-ubuntu","Authorization":"Basic "+b64})
    try:
        resp=urllib.request.urlopen(req,timeout=15)
        body=resp.read(4096)
        if resp.status==200 and (b"git-upload-pack" in body or b"refs/" in body):
            print("OK\t"+repo); sys.exit(0)
        last=repo+": 响应内容异常"
    except urllib.error.HTTPError as e:
        last=repo+": HTTP %s（401=凭据被拒，404=无该仓库权限）"%e.code
    except Exception as e:
        last=repo+": "+str(e)[:120]
print("ERR\t"+last)')
  KIND=${R%%$'\t'*}; DETAIL=${R#*$'\t'}
  if [ "$KIND" = "OK" ]; then
    step OK 'git 握手(clone路径)' "$DETAIL —— info/refs 认证通过（等价 ls-remote 成功）"
  else
    step FAIL 'git 握手(clone路径)' "$DETAIL"
  fi
  unset GHTOKEN TOKEN
fi

finish
