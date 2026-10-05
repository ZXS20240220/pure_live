import json
import os
import sys
import urllib.error
import urllib.request

# 本脚本仅服务于 dev_from_v3.1.4 发布通道：
# 只重建“本 Fork 自己”的 Release 历史，绝不合并上游
# liuchuancong/pure_live 的旧版本（Windows 客户端不应出现上游 apk 记录）。
#
# 输出严格沿用 build_portable&release.yml 中 `gh release view --json`
# 生成的 camelCase 结构（{"releases": [...]}），客户端 ReleaseModel
# 无需新增任何解析分支；扩展字段为 author.avatar（REST API 可提供，
# gh release view 不返回）与 isLatest（取自 /releases/latest）。
REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ZXS20240220/pure_live")
OUTPUT_FILE = "assets/releases.json"
PAGE_SIZE = 100


def fetch_page(url, token):
    headers = {
        "User-Agent": "PureLive-Fork-Release-Sync",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        print(f"正在获取发布数据: {url}")
        with urllib.request.urlopen(req, timeout=30) as response:
            raw_data = response.read()
        if not raw_data:
            print("❌ 错误：接口返回内容为空", file=sys.stderr)
            sys.exit(1)
        data = json.loads(raw_data.decode("utf-8"))
        if not isinstance(data, list):
            print("❌ 错误：Release 接口返回了非列表数据", file=sys.stderr)
            sys.exit(1)
        return data
    except urllib.error.HTTPError as e:
        print(f"❌ HTTP 错误：[{e.code}] {e.reason}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"❌ 网络连接失败（可能超时或域名无法解析）: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError:
        print("❌ 错误：返回内容不是合法的 JSON 格式", file=sys.stderr)
        sys.exit(1)


def convert_asset(asset):
    # 字段名与顺序对齐现有 releases.json（gh release view 的 assets 结构）。
    return {
        "apiUrl": asset.get("url"),
        "contentType": asset.get("content_type"),
        "createdAt": asset.get("created_at"),
        "digest": asset.get("digest") or "",
        "downloadCount": asset.get("download_count", 0),
        "id": asset.get("node_id") or str(asset.get("id", "")),
        "label": asset.get("label") or "",
        "name": asset.get("name"),
        "size": asset.get("size", 0),
        "state": asset.get("state"),
        "updatedAt": asset.get("updated_at"),
        "url": asset.get("browser_download_url"),
    }


def convert_release(release, latest_tag):
    author = release.get("author") or {}
    tag_name = release.get("tag_name")
    is_prerelease = bool(release.get("prerelease", False))
    return {
        "assets": [convert_asset(asset) for asset in release.get("assets", [])],
        "author": {
            "id": author.get("node_id") or str(author.get("id", "")),
            "login": author.get("login"),
            # ReleaseModel.fromJson 读取 author.avatar；
            # REST API 的 avatar_url 指向稳定的 avatars.githubusercontent.com 地址。
            "avatar": author.get("avatar_url"),
        },
        "body": release.get("body") or "",
        "isDraft": False,
        "isPrerelease": is_prerelease,
        # GitHub 的 Latest 标记只属于一个非预发布 Release，以
        # /releases/latest 返回的 tag 为准，避免仅凭发布时间猜测。
        "isLatest": bool(latest_tag and tag_name == latest_tag and not is_prerelease),
        "name": release.get("name"),
        "publishedAt": release.get("published_at"),
        "tagName": tag_name,
        "url": release.get("html_url"),
    }


def fetch_latest_tag(token):
    """返回 GitHub 标记为 Latest 的 Release tag；尚无正式版（404）时返回 None。"""
    url = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"
    headers = {
        "User-Agent": "PureLive-Fork-Release-Sync",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
        return data.get("tag_name")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("ℹ️ 仓库当前没有 Latest（正式版）Release，isLatest 将全部为 false。")
            return None
        # Latest 端点异常不应阻断整个 feed 同步，降级为无 Latest 标记。
        print(f"⚠️ 获取 Latest Release 失败：[{e.code}] {e.reason}，本次不写 isLatest。", file=sys.stderr)
        return None
    except urllib.error.URLError as e:
        print(f"⚠️ 获取 Latest Release 网络失败：{e.reason}，本次不写 isLatest。", file=sys.stderr)
        return None


def main():
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

    releases = []
    page = 1
    while True:
        url = (
            f"https://api.github.com/repos/{REPOSITORY}/releases"
            f"?per_page={PAGE_SIZE}&page={page}"
        )
        batch = fetch_page(url, token)
        if page == 1 and not batch:
            # 拒绝用空数据覆盖既有 feed（通常意味着接口异常或仓库配置错误）。
            print("❌ 错误：未获取到任何 Release，拒绝覆盖现有 releases.json", file=sys.stderr)
            sys.exit(1)
        releases.extend(batch)
        if len(batch) < PAGE_SIZE:
            break
        page += 1

    # GITHUB_TOKEN 对本仓库有权限时，列表接口会返回 draft；草稿不得进入更新源。
    published = [
        release
        for release in releases
        if not release.get("draft") and release.get("tag_name")
    ]
    if not published:
        print("❌ 错误：没有任何已发布的 Release，拒绝覆盖现有 releases.json", file=sys.stderr)
        sys.exit(1)

    published.sort(key=lambda release: release.get("published_at") or "", reverse=True)
    latest_tag = fetch_latest_tag(token)
    result = {"releases": [convert_release(release, latest_tag) for release in published]}

    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    # newline="\n" 强制 LF：仓库内 JSON 统一使用 LF，避免在 Windows
    # 本地运行时被文本模式翻译成 CRLF 而产生整文件 diff。
    with open(OUTPUT_FILE, "w", encoding="utf-8", newline="\n") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"生成完成: {OUTPUT_FILE}，共 {len(published)} 条发布（仓库 {REPOSITORY}）。")


if __name__ == "__main__":
    main()
