"""在 Gitee 创建发行版（供 CI 调用）。

用法：python scripts/gitee_release.py <tag> [zip路径] [release-notes.md]
需要环境变量 GITEE_TOKEN（projects 权限）。
若该 tag 的发行版已存在则幂等复用；zip 路径可省——本项目当前零附件发行。
注意：如未来需要上传附件，GitHub 机房直传 Gitee 大文件不可用（quad-todo P-009
实测 API 与 git 协议双双超时），附件须在维护者本地网络执行本脚本补传。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlencode

OWNER = "geekkkk404"
REPO = "sandbox-ubuntu"
API = f"https://gitee.com/api/v5/repos/{OWNER}/{REPO}"


def call(url_suffix: str, token: str, *, payload: bytes | None = None,
         headers: dict | None = None, timeout: int = 240, retries: int = 2):
    sep = "&" if "?" in url_suffix else "?"
    url = f"{API}/{url_suffix}{sep}access_token={token}"
    method = "POST" if payload is not None else "GET"
    last = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, data=payload, headers=headers or {},
                                     method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = resp.read()
            return json.loads(data.decode("utf-8")) if data.strip() else {}
        except urllib.error.HTTPError as e:
            # 绝不打印完整 url（含 token），只带路径与响应体，便于定位
            detail = e.read().decode("utf-8", "replace")[:500]
            raise SystemExit(f"Gitee API 失败 {e.code} [{url_suffix}]: {detail}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = e
            print(f"[{attempt}/{retries}] 网络错误（{e}），10 秒后重试…", flush=True)
            time.sleep(10)
    raise SystemExit(f"Gitee API 重试 {retries} 次仍失败 [{url_suffix}]: {last}")


def multipart(field: str, filename: str, content: bytes):
    b = uuid.uuid4().hex
    body = (f"--{b}\r\n"
            f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
            f"Content-Type: application/zip\r\n\r\n").encode("utf-8")
    body += content + f"\r\n--{b}--\r\n".encode("utf-8")
    return body, {"Content-Type": f"multipart/form-data; boundary={b}"}


def main() -> None:
    tag = sys.argv[1]
    zip_arg = sys.argv[2] if len(sys.argv) > 2 else ""
    notes_file = sys.argv[3] if len(sys.argv) > 3 else None
    token = os.environ["GITEE_TOKEN"]
    notes = Path(notes_file).read_text(encoding="utf-8") if notes_file else ""

    releases = call("releases?per_page=50", token)
    rel = next((r for r in releases if r.get("tag_name") == tag), None)
    if rel is None:
        # Gitee API v5：target_commitish 必填（即使 tag 已存在），表单编码而非 JSON
        form = urlencode({"tag_name": tag, "name": f"sandbox-ubuntu {tag}",
                          "body": notes, "prerelease": "false",
                          "target_commitish": "main"}).encode("utf-8")
        rel = call("releases", token, payload=form,
                   headers={"Content-Type": "application/x-www-form-urlencoded"})
        print("Gitee release created:", rel.get("tag_name"), "id", rel.get("id"))
    else:
        print("Gitee release exists:", rel.get("tag_name"), "id", rel.get("id"))

    if zip_arg and Path(zip_arg).is_file():
        zip_path = Path(zip_arg)
        body, headers = multipart("file", zip_path.name, zip_path.read_bytes())
        headers["Connection"] = "close"
        result = call(f"releases/{rel['id']}/attach_files", token,
                      payload=body, headers=headers, timeout=600)
        print("attached:", result.get("name") if isinstance(result, dict) else result)
    else:
        print("未提供 zip，跳过附件上传（本项目零附件发行；如需附件请在本地网络执行本脚本补传）")
    print("URL:", rel.get("html_url") or f"https://gitee.com/{OWNER}/{REPO}/releases/tag/{tag}")


if __name__ == "__main__":
    main()
