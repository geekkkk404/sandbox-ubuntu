# sandbox-ubuntu

[English](README.en.md) | 简体中文

**WSL2 上的一次性全新 Ubuntu 云机模拟器。** 双击进入一台 root 直进、systemd 运行中、apt 源按「新机档案」对齐（腾讯云 / 阿里云 / GCP·AWS·Azure 官方源）的"全新 Ubuntu LTS"，退出 shell 即校验式销毁，零残留。可选注入 GitHub 身份（默认纯净模式，无任何凭据进入沙箱）。

## 适用场景

- 测试安装脚本 / 一键脚本 / 部署文档：反复在"新机"上验证，不污染宿主、不租真机
- 复现"我服务器（22.04）上才有的问题"：选对应版本，拿到的就是那个版本的新机
- 练习 VPS 开荒全流程（apt update → 装 nginx → systemctl）：每一步都和真机一致
- 验证私有仓库在新机器上能否 clone + 构建（可选身份模式）

## 支持矩阵

| 版本 | 官方 rootfs 来源 | apt 源格式 | 母版 |
|---|---|---|---|
| 24.04 LTS (Noble) | releases.ubuntu.com (.wsl) | deb822 | 按需构建 |
| 22.04 LTS (Jammy) | cloud-images.ubuntu.com (rootfs.tar.gz) | 传统 one-line | 按需构建 |
| 26.04 LTS (Resolute) | releases.ubuntu.com (.wsl) | deb822 | 按需构建 |

- 全部 SHA256 固定于 [versions.json](versions.json)，下载后强校验；构建出的母版在每次启动时再校验一次（防损坏/误改）。
- **多源下载**：官方源优先、国内镜像（TUNA / USTC / NJU）回退，带低速熔断——20 秒内低于 100KB/s 即放弃当前尝试换下一个源（每个源有一次断点续传的补救机会，"前快后堵"的传输不作废）；每个源下载完成立即校验 SHA256，不匹配同样换源。实测国内网络下官方源 ~150KB/s（ETA 40+ 分钟）时自动切换 NJU 镜像可达 ~4MB/s。源顺序可在 versions.json 里自行调整（例如国内用户把镜像放最前）。
- 选项集刻意等于"云厂商在售 LTS"：这不是限制，是保真度的一部分。EOL 与 interim 版本不支持。

## 新机档案（profile）：模拟哪家云的新机

母版每版本只有一个，保持**出厂官方源**；apt 源在**沙箱启动时**按所选档案对齐到目标云的等价公网源（只改本次实例，随销毁消失）。新增一家云 = versions.json 加几行配置，母版与磁盘成本不翻倍。

| 档案 | apt 源（启动期对齐） | 对应目标 |
|---|---|---|
| `stock` | `archive.ubuntu.com`（保持官方，不改源） | GCP / AWS / Azure 新机即官方源；海外用户默认 |
| `tencent`（默认） | `mirrors.cloud.tencent.com` | 腾讯云新机 |
| `aliyun` | `mirrors.aliyun.com` | 阿里云新机 |

- **为什么用公网等价源**：真机的源指向云内网域名（`mirrors.tencentyun.com` 等），云外不可达；照抄会模拟出真实云用户遇不到的假障碍，公网等价源才是可测的保真。
- **已知边界（如实告知）**：云厂商私有 agent（阿里云助手 / SSM Agent / 云监控插件）不模拟；内核为 WSL 定制内核（见下）；metadata service 不存在。档案对齐的是"新机开机后你能观察到的软件源与基线包"。

## 快速开始

0. 前置：Windows 10 (19041+) / 11，已装 WSL2（`wsl --install`，家庭版可用，无需第三方虚拟化软件）。
1. 下载本项目（ZIP 解压或 git clone）。
2. 双击 `start-sandbox.cmd` → 菜单选版本与新机档案 → 首次选中未构建的版本会询问是否联网构建母版（几分钟，之后有缓存）。
3. 进入 root shell，开始使用。
4. **退出只有一种方式：在沙箱里输 `exit`**。直接点窗口 X 会让清理代码没机会执行，留下约 2GB vhdx 残留；异常残留会在下次启动自动清除，或双击 `cleanup.cmd` 手动兜底。

可选：GitHub 身份模式——把 `token.example.txt` 复制为 `token.txt` 并填入你的 fine-grained PAT（仅勾选需要的仓库、Contents 只读、7~30 天有效期）。存在 `token.txt` 即启用，否则纯净模式。

## 参数

```
start-sandbox.cmd                        # 交互菜单选版本+新机档案，进入沙箱
start-sandbox.cmd -Version 22.04         # 指定版本，跳过菜单
start-sandbox.cmd -Profile stock         # 指定新机档案（stock/tencent/aliyun），跳过档案菜单
start-sandbox.cmd -SkipShell             # 只做 构建/导入/验证/清理（自动化验证）
start-sandbox.cmd -NoIdentity            # 即使 token.txt 存在也强制纯净模式
start-sandbox.cmd -Force                 # 验证失败不询问，直接清理退出
start-sandbox.cmd -ListVersions          # 打印支持矩阵（版本 × 新机档案）
build-base.ps1 -Version 22.04 -Force     # 手动重建某版本母版（下载缓存一并作废需重下）
build-base.ps1 -Mirror <url>             # 海外构建时可覆盖构建期加速镜像（默认腾讯云源）
cleanup.cmd                              # 异常残留兜底（校验式清理 + 如实报告）
```

## 保真基线（母版烤入了什么）

- **apt 源**：母版保持**出厂官方源**（`archive.ubuntu.com` / `security.ubuntu.com`，格式随版本：24.04/26.04 为 deb822 `ubuntu.sources`，22.04 为传统 `sources.list`）。目标云的源对齐发生在每次沙箱启动时（按新机档案，见上），只作用于本次实例。
- **sshd + cloud-init + ca-certificates**：新 VPS 自带 → 必须有；`cloud-init clean` 已执行，每次启动都跑新机首启流程。
- **git / pip / gcc / node / docker：一律不烤**——新机没有的就没有，`apt install git` 本身是模拟的一部分，每次启动自检确认 git 缺席。
- **systemd 运行中**，`systemctl` 可用；默认 root 直进；主机名固定 `ubuntu`。
- **apt 包列表已清空**：首启第一次 `apt update` 需要你自己跑，与新机一致。
- **隔离**：`/etc/wsl.conf` 关闭 automount（看不到宿主硬盘）、interop（调不到 Windows exe）、appendWindowsPath。

### 已知保真边界（如实告知）

- 内核：WSL 定制内核 ≠ 云厂商内核（AWS `linux-aws`、GCP `linux-gcp` 等），内核参数/驱动/DKMS 类演练无法复现。
- 云厂商私有 agent：阿里云助手 / SSM Agent / 云监控插件等不模拟——它们不改变新机的 apt/基线行为，属刻意边界而非遗漏。
- cloud-init：datasource 是 WSL 而非云厂商，首启流程会跑但实例元数据与云上不同。
- 网络出口：走你本机网络链路，不是云厂商机房线路。

## 两种模式

| | 纯净模式（默认） | 身份模式（token.txt 存在时） |
|---|---|---|
| 进入沙箱的凭据 | 无 | fine-grained PAT（经 WSLENV 内存桥，不落盘传输） |
| 验证 | 基线自检 + apt 镜像可达 | 基线自检 + apt 镜像 + GitHub 三段验证（网络/身份/git 握手） |
| 典型用途 | 测安装脚本、练习开荒、跑不完全信任的东西 | 验证私有仓库 clone/构建 |
| token 去向 | 不存在 | `/root/.git-credentials`（600 权限），随 vhdx 销毁 |

git 握手验证的原理：沙箱内没有 git（基线要求），setup 用 python 直接发 `*.git/info/refs?service=git-upload-pack` + Basic 认证——200 + advertisement 即等价 `git ls-remote` 成功。

## 安全边界（务必阅读 [docs/threat-model.md](docs/threat-model.md)）

- **WSL2 不是安全边界**。纯净模式给的是一个"干净环境"，不是对抗性沙箱。
- 身份模式下，**任何在 guest 内以 root 跑的代码都能读走 token 并外传**。跑不完全信任的代码请用 `-NoIdentity`。
- 销毁是校验式的：unregister → 删 vhdx → 复查注册表与磁盘，失败会红字报警而不是谎报成功。

## 与其他方案对比

| | 本项目 | docker run --rm | Multipass | VM 快照 | 真云按量实例 |
|---|---|---|---|---|---|
| Windows 家庭版 | ✔ | ✔ | ✘（需 Hyper-V/Pro） | VBox 可 | ✔ |
| systemd / cloud-init 首启 | ✔ | ✘ | ✔（NoCloud） | ✔ | ✔ |
| 每次全新 + 销毁保证 | 校验式 | 构造级 | 需记得 --purge | 还原快照 | 需记得销毁 |
| 云镜像源对齐 | ✔（按新机档案：腾讯云/阿里云/官方） | ✘ | ✘（官方源） | ✘ | ✔ |
| 后续每次启动 | 30–60 秒 | ~10 秒 | ~1 分钟 | ~2 分钟 | 5–10 分钟 |

## 目录结构

| 文件 | 作用 |
|---|---|
| `versions.json` | 支持矩阵：版本 / 官方 rootfs URL / SHA256 / apt 源格式 / 新机档案（profiles）/ 构建期加速镜像 |
| `build-base.ps1` | 按版本构建母版（下载→校验→对齐基线→还原出厂源→导出 .tar+.sha256→销毁构建实例） |
| `guest-build.sh` | 构建实例内执行：基线包 / wsl.conf / cloud-init 重置（构建期用镜像加速，母版保持出厂官方源） |
| `start-sandbox.cmd` / `.ps1` | 主流程：选版本与档案→清理→导入→注入→验证→shell→销毁 |
| `setup.sh` | guest 内：基线自检 + apt 源按档案对齐 + 源可达 +（身份模式）注入与三段验证 |
| `cleanup.cmd` / `cleanup.ps1` | 校验式兜底清理（含构建实例残留） |
| `token.example.txt` → `token.txt` | 可选 GitHub 身份（你创建，已被 .gitignore 排除） |
| `base\` / `download\` / `instance\` / `logs\` | 母版 / rootfs 缓存 / 运行期 vhdx / 日志（均已 gitignore） |

## 排障

- **[FAIL] apt 镜像不可达**：宿主网络/代理问题，沙箱继承宿主链路；国内网络选 `stock` 档案时官方源可能超时，属预期（真实行为），换回 `tencent`/`aliyun` 即可。
- **[FAIL] 源对齐（profile=stock 但源非官方）**：母版是旧版构建（带云镜像源），`build-base.ps1 -Version <id> -Force` 重建母版即可。
- **（身份模式）[FAIL] 身份 HTTP 401**：token 错/过期，改 token.txt 重开。
- **（身份模式）[FAIL] git 握手 404/401**：fine-grained token 没勾该仓库或 Contents 权限不足。
- **母版 SHA256 不匹配**：`build-base.ps1 -Version <id> -Force` 重建。
- 日志：`logs\setup-<版本>-<时间>.txt`、`logs\result-latest.txt`（含 `profile=` 行）、`logs\build-<版本>-<时间>.txt`（绝不含 token）。

## License

[MIT](LICENSE)
