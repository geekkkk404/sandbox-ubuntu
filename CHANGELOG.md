# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows SemVer.

## [0.1.0] - 2026-11-01

Initial public release / 首个公开版本。

### Added

- Disposable "fresh Ubuntu cloud VPS" simulator on WSL2: double-click into a root shell on a pristine Ubuntu LTS (systemd running), verified teardown on exit (unregister → delete vhdx → re-check), zero leftovers. / WSL2 上的一次性全新 Ubuntu 云机模拟器：双击进入全新 Ubuntu LTS（root 直进、systemd 运行中），退出即校验式销毁（unregister → 删 vhdx → 复查），零残留。
- Machine profiles: apt sources aligned at instance start to a cloud vendor's public-equivalent mirror — `stock` (GCP/AWS/Azure), Tencent Cloud, Alibaba Cloud; one base image per Ubuntu release, disk and build cost do not multiply per cloud. / 新机档案：启动期把 apt 源对齐到目标云的公网等价源（stock / 腾讯云 / 阿里云）；母版每版本唯一，磁盘与构建成本不随云数量翻倍。
- Supported LTS: 22.04 / 24.04 / 26.04 — official rootfs with SHA256 pinning; multi-source download (official first, CN mirrors fallback) with low-speed circuit breaker and resumable retries. / 三代 LTS（22.04 / 24.04 / 26.04）：官方 rootfs + SHA256 强校验；多源下载（官方优先、国内镜像回退）带低速熔断与断点续传。
- Baseline fidelity: sshd + cloud-init + ca-certificates baked in, `cloud-init clean` first-boot flow, apt package lists empty, git/pip/gcc deliberately absent, isolation via wsl.conf (no host mounts, no interop). / 新机保真基线：sshd/cloud-init/ca-certificates、cloud-init 首启流程、apt 列表清空、git 等刻意缺席、wsl.conf 隔离。
- Optional GitHub identity mode: fine-grained PAT via WSLENV in-memory bridge, 3-stage verification (network / identity / git handshake), credentials die with the instance; token never printed to any log. / 可选 GitHub 身份模式：fine-grained PAT 经 WSLENV 内存桥注入、三段验证、凭据随实例销毁，token 绝不进日志。
- Programmatic / AI-agent usage: unattended `-SkipShell` mode, deterministic exit codes, machine-readable `logs/result-latest.txt` (`status=/version=/profile=/mode=` + per-check `PASS/FAIL` lines). / 无人值守调用：`-SkipShell`、确定性退出码、机器可读的 `logs/result-latest.txt`。
- WSL-missing diagnosis on startup: distinguishes component missing / BIOS virtualization off / hypervisor launch disabled, with copy-paste fix guidance. / 启动期 WSL 缺失诊断：区分组件未装 / BIOS 虚拟化未开 / hypervisor 被关，并给可复制的修复指引。
- Threat model document ([docs/threat-model.md](docs/threat-model.md)): WSL2 is not a security boundary; identity-mode token exposure stated honestly. / 威胁模型文档：如实声明 WSL2 不是安全边界与身份模式 token 暴露面。
