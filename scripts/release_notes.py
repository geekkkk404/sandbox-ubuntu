"""从 CHANGELOG.md 抽取指定版本的段落作为发行说明（供 CI 调用）。

用法：python scripts/release_notes.py <tag>    # 如 v0.2.0
输出 `## [x.y.z] - 日期` 段落的正文（不含标题行、不含文末 `[x.y.z]:` 链接定义）到 stdout。
段落不存在或正文为空则非零退出——CI 据此拦下「CHANGELOG 忘写就发版」。
"""
import re
import sys
from pathlib import Path

CHANGELOG = Path(__file__).resolve().parent.parent / "CHANGELOG.md"


def main() -> None:
    tag = sys.argv[1] if len(sys.argv) > 1 else ""
    version = tag[1:] if tag.startswith("v") else tag
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit(f"tag 需形如 v0.2.0（当前输入：{tag or '空'}）")

    text = CHANGELOG.read_text(encoding="utf-8")
    head = re.search(rf"(?m)^## \[{re.escape(version)}\][^\n]*\n", text)
    if not head:
        raise SystemExit(f"CHANGELOG.md 里没有 {version} 的版本段（先写好 `## [{version}] - 日期` 再发版）。")

    body = []
    for line in text[head.end():].splitlines():
        if line.startswith("## ") or re.match(r"^\[[^\]]+\]:\s*\S", line):
            break  # 下一个版本段，或文末链接定义——段落到此为止
        body.append(line)
    notes = "\n".join(body).strip()
    if not notes:
        raise SystemExit(f"CHANGELOG.md 的 {version} 段落是空的，先写更新内容。")
    print(notes)


if __name__ == "__main__":
    main()
