# sandbox-ubuntu

English | [简体中文](README.md)

**A disposable "fresh Ubuntu cloud VPS" simulator on WSL2 (Windows only).** Double-click to enter a root shell on a brand-new Ubuntu LTS (systemd running, apt sources aligned per cloud "profile": Tencent Cloud / Aliyun / GCP·AWS·Azure stock), and the instance is verified-destroyed the moment you exit. Clean mode (no credentials) is the default; GitHub identity injection is strictly opt-in.

> **TL;DR**: double-click on Windows and get a "fresh Ubuntu cloud VPS" — systemd running, root login, apt sources aligned to a cloud vendor's fresh-machine mirror (stock / Tencent / Aliyun), verified teardown with zero leftovers on exit. Built for repeatedly testing install scripts and deployment docs on a brand-new machine. Unattended / AI-agent invocation: see "Programmatic / AI-agent usage" below.

## Use cases

- Testing install scripts / bootstrap scripts / deployment docs against a fresh machine, repeatedly, without polluting the host or renting a real VPS.
- Reproducing "it only breaks on my 22.04 server": pick that version, get a pristine machine of exactly that release.
- Practicing the full VPS onboarding flow (apt update → install nginx → systemctl).
- Verifying a private repo can be cloned + built on a clean machine (opt-in identity mode).

## Supported versions

| Version | Official rootfs source | apt source style | Base image |
|---|---|---|---|
| 24.04 LTS (Noble) | releases.ubuntu.com (.wsl) | deb822 | built on demand |
| 22.04 LTS (Jammy) | cloud-images.ubuntu.com (rootfs.tar.gz) | legacy one-line | built on demand |
| 26.04 LTS (Resolute) | releases.ubuntu.com (.wsl) | deb822 | built on demand |

- All downloads are SHA256-pinned in [versions.json](versions.json); the built base image is re-verified on every start.
- **Multi-source downloads**: official source first, CN mirrors (TUNA / USTC / NJU) as fallback, with a low-speed circuit breaker — if throughput stays below 100KB/s for 20 seconds the attempt is abandoned and the next source tried (each source gets one resumable second chance, so a "fast-then-stall" transfer is not thrown away); every source's download is SHA256-verified before acceptance. Measured on a CN connection: official source ~150KB/s (ETA 40+ min) auto-switches to the NJU mirror at ~4MB/s. Source order can be adjusted in versions.json (e.g. mirrors first for CN users).
- The picker intentionally mirrors what cloud vendors actually sell: active LTS releases only. EOL and interim releases are not supported.

## Machine profiles: simulating a fresh machine from a specific cloud

There is exactly one base image per Ubuntu release, kept at **stock sources**. At sandbox start, apt sources are aligned to the chosen profile's public-equivalent mirror — inside the running instance only, destroyed with it. Adding a cloud vendor is a few lines in versions.json; base images and disk cost do not multiply.

| Profile | apt sources (aligned at start) | Models |
|---|---|---|
| `stock` | `archive.ubuntu.com` (kept official, no rewrite) | GCP / AWS / Azure fresh machines use stock sources; default for non-CN users |
| `tencent` (default) | `mirrors.cloud.tencent.com` | Tencent Cloud |
| `aliyun` | `mirrors.aliyun.com` | Alibaba Cloud |

- **Why public equivalents**: real cloud machines point at intra-VPC mirror domains (`mirrors.tencentyun.com` etc.) that only resolve inside the cloud network; copying them verbatim would simulate an obstacle real users never hit. The public equivalent is the testable form of the same fidelity.
- **Known limits (stated honestly)**: vendor-private agents (Aliyun Assistant / SSM Agent / monitoring plugins) are not simulated; the kernel is WSL's (see below); there is no metadata service. A profile aligns what you can actually observe on a fresh machine: its software sources and baseline packages.

## Quick start

1. Prerequisite: Windows only — Windows 10 (19041+) / 11 with WSL2 installed (`wsl --install`; Windows Home works, no third-party virtualization needed). If WSL is missing, the launcher prints a precise diagnosis (component missing / BIOS virtualization off / hypervisor disabled) with step-by-step fix guidance. macOS / Linux hosts have no WSL and are not supported.
2. Download this project (ZIP or `git clone`).
3. Double-click `start-sandbox.cmd`, pick a version and a machine profile. On first use it offers to download the official rootfs and build the base image (a few minutes, cached afterwards).
4. You are in a root shell. Do your thing.
5. **The only correct exit is typing `exit` inside the sandbox.** Closing the window skips cleanup and leaves a ~2GB vhdx behind; leftovers are auto-cleaned on next start, or run `cleanup.cmd`.

Optional identity mode: copy `token.example.txt` to `token.txt` and paste a fine-grained PAT (selected repos only, read-only Contents, 7–30 day expiry). If `token.txt` exists, identity mode is on; otherwise the sandbox starts clean.

## Parameters

```
start-sandbox.cmd                        # interactive version + profile menu
start-sandbox.cmd -Version 22.04         # skip the menus
start-sandbox.cmd -Profile stock         # pick the machine profile (stock/tencent/aliyun)
start-sandbox.cmd -SkipShell             # build/import/verify/cleanup only (for automation)
start-sandbox.cmd -NoIdentity            # force clean mode even if token.txt exists
start-sandbox.cmd -Force                 # on verification failure: clean up without asking
start-sandbox.cmd -ListVersions          # print the support matrix (versions × profiles)
build-base.ps1 -Version 22.04 -Force     # rebuild a base image
build-base.ps1 -Mirror <url>             # override the build-time apt mirror (default: Tencent Cloud)
cleanup.cmd                              # verified cleanup for leftovers
```

## Programmatic / AI-agent usage

Designed to be callable unattended: no interaction, machine-readable results, deterministic exit codes. Recommended agent invocation:

```
start-sandbox.cmd -SkipShell -Version 22.04 -Profile stock -NoIdentity -Force
```

- `-SkipShell`: no interactive shell; runs build → import → init & verify → verified cleanup, then exits. Builds a missing base image automatically — safe unattended.
- `-NoIdentity`: force clean mode even if token.txt exists — the recommended posture before running semi-trusted code.
- `-Force`: on verification failure, clean up and exit without asking.
- Every call is a brand-new machine: stateless and repeatable; read back the exit code and `logs\result-latest.txt`.

**Reading the result (machine-readable):**

- **Exit code**: `0` = verification passed and zero-leftover cleanup confirmed; `1` = any step failed (environment check / build / import / verify / cleanup).
- **`logs\result-latest.txt`**: starts with machine-readable key=value lines — `status=OK|FAIL`, `version=`, `profile=`, `mode=pure|identity`, `time=`; then one `PASS|FAIL<TAB>check<TAB>detail` line per check.
- **Logs**: `logs\setup-<version>-<time>.txt` (init & verify), `logs\build-<version>-<time>.txt` (base build); never contain the token.

## Fidelity baseline (what is baked into the base image)

- **apt sources**: the base image keeps **stock official sources** (`archive.ubuntu.com` / `security.ubuntu.com`, deb822 `ubuntu.sources` on 24.04/26.04, classic `sources.list` on 22.04). Cloud-source alignment happens at every sandbox start, per machine profile (see above), inside the running instance only.
- **sshd + cloud-init + ca-certificates** are present (a fresh VPS has them); `cloud-init clean` was executed, so every start runs the first-boot flow.
- **git / pip / gcc / node / docker are NOT installed** — what a fresh machine lacks, it lacks. `apt install git` is part of the simulation; every start asserts git is absent.
- **systemd running**, root login, hostname fixed to `ubuntu`.
- **apt package lists are empty**: your first `apt update` is yours to run, like on a real machine.
- **Isolation**: `/etc/wsl.conf` disables automount (no host drives), interop (no Windows executables), appendWindowsPath.

### Known fidelity limits (stated honestly)

- Host platform: Windows only (WSL2); macOS / Linux hosts lack WSL and are not supported.
- Kernel: WSL's custom kernel ≠ cloud vendor kernels (`linux-aws`, `linux-gcp`, …); kernel/DKMS-level drills can't be reproduced.
- Vendor-private agents: Aliyun Assistant / SSM Agent / monitoring plugins are not simulated — they don't change a fresh machine's apt/baseline behavior; a deliberate boundary, not an omission.
- cloud-init: the datasource is WSL, not a cloud vendor; first-boot runs but instance metadata differs.
- Egress: your local network path, not a datacenter route.

## Two modes

| | Clean mode (default) | Identity mode (token.txt present) |
|---|---|---|
| Credentials entering the sandbox | none | fine-grained PAT (via WSLENV in-memory bridge only) |
| Verification | baseline self-check + apt mirror reachable | + GitHub 3-stage check (network / identity / git handshake) |
| Typical use | install-script testing, onboarding practice, semi-trusted code | private repo clone/build verification |
| Token fate | never exists | `/root/.git-credentials` (mode 600), dies with the vhdx |

The git-handshake check: the sandbox has no git by design, so setup sends the exact first request of `git ls-remote` (`*.git/info/refs?service=git-upload-pack` + Basic auth) with python — a 200 with an advertisement proves the clone path authenticates.

## Security boundary (read [docs/threat-model.md](docs/threat-model.md))

- **WSL2 is not a security boundary.** Clean mode gives you a fresh environment, not an adversarial sandbox.
- In identity mode, **any code running as root inside the guest can read the token and exfiltrate it**. Use `-NoIdentity` for semi-trusted code.
- Destruction is verified: unregister → delete vhdx → re-check registry and disk; failures are reported loudly, never silently assumed.

## Comparison with alternatives

| | this project | docker run --rm | Multipass | VM snapshot | hourly cloud VM |
|---|---|---|---|---|---|
| Windows Home | ✔ | ✔ | ✘ (Hyper-V/Pro) | VBox: ✔ | ✔ |
| systemd / cloud-init first boot | ✔ | ✘ | ✔ (NoCloud) | ✔ | ✔ |
| fresh-every-time + teardown guarantee | verified | by construction | remember --purge | revert snapshot | remember to destroy |
| cloud mirror alignment | ✔ (per machine profile: Tencent / Aliyun / stock) | ✘ | ✘ (stock sources) | ✘ | ✔ |
| startup cost after first use | 30–60 s | ~10 s | ~1 min | ~2 min | 5–10 min |

## FAQ

**Q: Can I run semi-trusted code in it?**
Clean mode (the default) gives you a fresh environment, not an adversarial sandbox — WSL2 is not a security boundary. Keep clean mode for untrusted code; in identity mode, root inside the guest can read the token. See [threat-model](docs/threat-model.md).

**Q: How is this different from `docker run --rm`?**
The "fresh machine first boot" semantics (systemd + cloud-init), verified teardown, and per-cloud apt-source alignment. In a container systemd is not PID1, so drills that install services (systemctl enable/start) go unrealistic — and that is one of this project's main use cases.

**Q: Why is git missing? My server has it.**
The baseline is a fresh-VPS factory state: git/pip/gcc are deliberately not baked in. `apt install git` is part of the simulation — it proves your deployment flow works on a new machine.

**Q: Is the data really gone after exit? Can it be recovered?**
Gone, and unrecoverable — that is the point. Teardown is verified (unregister → delete vhdx → re-check); push out anything you want to keep before typing `exit`.

**Q: Why public mirrors instead of the cloud's intra-VPC domain?**
Intra-VPC mirror domains (`mirrors.tencentyun.com` etc.) do not resolve outside the cloud; copying them verbatim would create an obstacle real cloud users never hit. The public equivalent is the testable form of the same fidelity.

**Q: Does it support macOS / Linux?**
No. It depends on WSL2, a Windows-only component — see "Known fidelity limits".

**Q: Can I run it inside Windows Sandbox?**
No. WSL2 needs nested virtualization, which Windows Sandbox does not provide (the launcher detects the sandbox and says so directly, instead of sending you down a dead end). To try the "clean machine first boot" experience, use a physical machine or a full VM with nested virtualization enabled: Hyper-V (`Set-VMProcessor -ExposeVirtualizationExtensions $true` on the host), VMware Workstation (enable "Virtualize Intel VT-x/EPT" in the VM settings), or a cloud VM size that supports nesting; VirtualBox offers nested virt on AMD hosts only.

**Q: How much disk does it use?**
~1–2GB per built base image (cached in `base\`, deletable and rebuildable); ~2GB vhdx while an instance runs, released on `exit`.

**Q: Does the token end up in logs?**
No. The token enters the sandbox through the WSLENV in-memory bridge and is never printed; credentials exist only at `/root/.git-credentials` inside the instance and die with it.

## Maintainer

- Author / maintainer: [geekkkk404](https://github.com/geekkkk404)
- Born from a real pain: reinstalling a system or renting a VPS just to test an install script. Known limits are documented honestly (see "Known fidelity limits") — no overpromising. Please open an issue for feedback.

## License

[MIT](LICENSE)
