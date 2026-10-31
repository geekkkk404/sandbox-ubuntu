# sandbox-ubuntu

English | [简体中文](README.md)

**A disposable "fresh Ubuntu cloud VPS" simulator on WSL2.** Double-click to enter a root shell on a brand-new Ubuntu LTS (systemd running, apt sources aligned with the Tencent Cloud mirror), and the instance is verified-destroyed the moment you exit. Clean mode (no credentials) is the default; GitHub identity injection is strictly opt-in.

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
- The apt mirror defaults to Tencent Cloud's public mirror; change it in versions.json.

## Quick start

1. Prerequisite: Windows 10 (19041+) / 11 with WSL2 installed (`wsl --install`; Windows Home works, no third-party virtualization needed).
2. Download this project (ZIP or `git clone`).
3. Double-click `start-sandbox.cmd`, pick a version. On first use it offers to download the official rootfs and build the base image (a few minutes, cached afterwards).
4. You are in a root shell. Do your thing.
5. **The only correct exit is typing `exit` inside the sandbox.** Closing the window skips cleanup and leaves a ~2GB vhdx behind; leftovers are auto-cleaned on next start, or run `cleanup.cmd`.

Optional identity mode: copy `token.example.txt` to `token.txt` and paste a fine-grained PAT (selected repos only, read-only Contents, 7–30 day expiry). If `token.txt` exists, identity mode is on; otherwise the sandbox starts clean.

## Parameters

```
start-sandbox.cmd                        # interactive version menu
start-sandbox.cmd -Version 22.04         # skip the menu
start-sandbox.cmd -SkipShell             # build/import/verify/cleanup only (for automation)
start-sandbox.cmd -NoIdentity            # force clean mode even if token.txt exists
start-sandbox.cmd -Force                 # on verification failure: clean up without asking
start-sandbox.cmd -ListVersions          # print the support matrix
build-base.ps1 -Version 22.04 -Force     # rebuild a base image
cleanup.cmd                              # verified cleanup for leftovers
```

## Fidelity baseline (what is baked into the base image)

- **apt sources**: aligned with Tencent Cloud's format per release (deb822 `ubuntu.sources` on 24.04/26.04, classic `sources.list` on 22.04), pointing at `mirrors.cloud.tencent.com/ubuntu/`. Cloud-internal mirror domains are deliberately not used (unresolvable via public DNS — copying them would simulate an obstacle real cloud users never hit).
- **sshd + cloud-init + ca-certificates** are present (a fresh VPS has them); `cloud-init clean` was executed, so every start runs the first-boot flow.
- **git / pip / gcc / node / docker are NOT installed** — what a fresh machine lacks, it lacks. `apt install git` is part of the simulation; every start asserts git is absent.
- **systemd running**, root login, hostname fixed to `ubuntu`.
- **apt package lists are empty**: your first `apt update` is yours to run, like on a real machine.
- **Isolation**: `/etc/wsl.conf` disables automount (no host drives), interop (no Windows executables), appendWindowsPath.

### Known fidelity limits (stated honestly)

- Kernel: WSL's custom kernel ≠ cloud vendor kernels; kernel-level drills can't be reproduced.
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
| cloud mirror alignment | ✔ (per version) | ✘ | ✘ (stock sources) | ✘ | ✔ |
| startup cost after first use | 30–60 s | ~10 s | ~1 min | ~2 min | 5–10 min |

## License

[MIT](LICENSE)
