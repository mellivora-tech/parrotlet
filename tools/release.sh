#!/bin/zsh
# 发版一条龙：tools/release.sh <semver>   例：tools/release.sh 0.2.0
#
# 流程：版本号写 Info.plist（CFBundleVersion 取 max(当天日期, 当前+1) 保证单调递增）
#   → make app（SPM 构建 + 内嵌 Sparkle + 稳定证书签名）
#   → zip → sign_update（EdDSA，私钥在本机 Keychain，公钥在 Info.plist SUPublicEDKey）
#   → gh release 上传 zip → 更新 releases 仓库 appcast.xml 并推送
# 完成后源码仓库会留下 Info.plist 的版本号改动，自行提交。
set -euo pipefail

VERSION="${1:?用法: tools/release.sh <semver>，例: tools/release.sh 0.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 发版仅维护者可用：需要本机 Keychain 里的 Sparkle EdDSA 私钥（generate_keys 生成，
# 见仓库 Wiki/README 的发版说明）。用空文件试签一次做 fail-fast——
# 外部贡献者误跑会在动 Info.plist / 构建之前拿到这句明白话，而不是一串莫名错误
GUARD="$(mktemp)"
if ! tools/sparkle/sign_update "$GUARD" >/dev/null 2>&1; then
    rm -f "$GUARD"
    echo "❌ 发版仅维护者可用：本机 Keychain 缺少 Sparkle EdDSA 私钥（tools/release.sh 头注释）" >&2
    exit 1
fi
rm -f "$GUARD"

RELEASES_REPO="mellivora-tech/parrotlet-releases"
REL_DIR="build/release-checkout"
ZIP="build/Parrotlet-$VERSION.zip"

# ---- 1. 版本号 ----
BUILD="$(date +%Y%m%d)"
CUR="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist 2>/dev/null || echo 0)"
if (( CUR >= BUILD )); then BUILD=$(( CUR + 1 )); fi
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" Info.plist
echo "==> 版本 $VERSION (build $BUILD)"

# ---- 2. 构建 ----
make app

# ---- 3. 打包 + EdDSA 签名 ----
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Parrotlet.app "$ZIP"
SIG_OUT="$(tools/sparkle/sign_update "$ZIP")"
SIG="$(print -r -- "$SIG_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LEN="$(stat -f%z "$ZIP")"
[ -n "$SIG" ] || { echo "sign_update 输出解析失败: $SIG_OUT" >&2; exit 1; }
echo "==> 已签名 (length=$LEN)"

# ---- 4. 上传 Release ----
[ -d "$REL_DIR/.git" ] || git clone -q "https://github.com/$RELEASES_REPO" "$REL_DIR"
git -C "$REL_DIR" fetch -q origin main && git -C "$REL_DIR" reset -q --hard origin/main
gh release create "v$VERSION" "$ZIP" --repo "$RELEASES_REPO" \
    --title "Parrotlet $VERSION" --notes "${NOTES:-Parrotlet $VERSION}"
echo "==> Release v$VERSION 已上传"

# ---- 5. 更新 appcast 并推送（最后一步：feed 引用已可下载的产物） ----
PUBDATE="$(date -R)"
VERSION="$VERSION" BUILD="$BUILD" SIG="$SIG" LEN="$LEN" PUBDATE="$PUBDATE" \
python3 - "$REL_DIR/appcast.xml" <<'PYEOF'
import os, sys

path = sys.argv[1]
v, b = os.environ["VERSION"], os.environ["BUILD"]
url = ("https://github.com/mellivora-tech/parrotlet-releases"
       f"/releases/download/v{v}/Parrotlet-{v}.zip")
item = f"""    <item>
      <title>Parrotlet {v}</title>
      <pubDate>{os.environ["PUBDATE"]}</pubDate>
      <sparkle:version>{b}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="{url}"
                 sparkle:edSignature="{os.environ["SIG"]}"
                 length="{os.environ["LEN"]}" type="application/octet-stream"/>
    </item>
"""
with open(path, encoding="utf-8") as f:
    xml = f.read()
marker = "  </channel>"
assert marker in xml, "appcast.xml 结构异常：找不到 </channel>"
xml = xml.replace(marker, item + marker, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
print("==> appcast 已插入 v" + v)
PYEOF

git -C "$REL_DIR" add appcast.xml
git -C "$REL_DIR" commit -qm "Parrotlet v$VERSION"
git -C "$REL_DIR" push -q origin main
echo ""
echo "✅ v$VERSION (build $BUILD) 已发布"
echo "   appcast: https://raw.githubusercontent.com/$RELEASES_REPO/main/appcast.xml"
echo "   （raw CDN 缓存 ~5 分钟，客户端稍后才能看到新版本）"
echo "   别忘了提交源码仓库的 Info.plist 版本号改动"
