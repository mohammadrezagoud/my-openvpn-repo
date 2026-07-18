#!/bin/bash
#
# publish-config-to-repo.sh
#
# فایل .ovpn ساخته‌شده را داخل خودِ ریپو کامیت و پوش می‌کند تا از طریق
# صفحه‌ی گیت‌هاب (دکمه‌ی Download در صفحه‌ی فایل) دانلودش کنی.
#
# هشدار امنیتی مهم:
#   این فایل شامل کلید خصوصی VPN است. فقط روی یک ریپوی PRIVATE این کار را بکن.
#   بعد از دانلود، حتماً این فایل را از ریپو حذف/کامیت کن (پایین توضیح داده شده)
#   یا اسکریپت اصلی را دوباره اجرا کن تا PKI از نو ساخته شود و این کلید بی‌اعتبار شود.
#
# استفاده:
#   bash publish-config-to-repo.sh [نام کلاینت]

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" 1>&2; }

CLIENT_NAME="${1:-client}"
CLIENT_DIR="${HOME}/openvpn-clients"
OVPN_FILE="${CLIENT_DIR}/${CLIENT_NAME}.ovpn"

if [[ ! -f "$OVPN_FILE" ]]; then
    err "فایل ${OVPN_FILE} پیدا نشد. اول codespace-openvpn.sh را اجرا کن."
    exit 1
fi

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_DIR" ]]; then
    err "این پوشه داخل یک ریپوی گیت نیست. داخل پوشه‌ی ریپو (my-openvpn-repo) اجرا کن."
    exit 1
fi

DEST_DIR="${REPO_DIR}/generated-configs"
DEST_FILE="${DEST_DIR}/${CLIENT_NAME}.ovpn"

mkdir -p "$DEST_DIR"
cp "$OVPN_FILE" "$DEST_FILE"

cd "$REPO_DIR"
# چون *.ovpn توی .gitignore است، با -f صراحتاً اضافه‌اش می‌کنیم
git add -f "generated-configs/${CLIENT_NAME}.ovpn"
git commit -m "Add temporary VPN client config for download (remove after use)"
git push

echo ""
ok "فایل با موفقیت پوش شد: generated-configs/${CLIENT_NAME}.ovpn"
info "برای دانلود:"
echo "   1. توی گیت‌هاب برو به مسیر: generated-configs/${CLIENT_NAME}.ovpn"
echo "   2. روی دکمه‌ی ⋯ (یا 'Raw') کلیک کن و 'Download raw file' را بزن."
echo ""
warn "بعد از دانلود، حتماً این فایل را از ریپو حذف کن تا کلید خصوصی توی تاریخچه‌ی گیت باقی نماند:"
echo "   git rm generated-configs/${CLIENT_NAME}.ovpn"
echo "   git commit -m \"Remove VPN client config\""
echo "   git push"
