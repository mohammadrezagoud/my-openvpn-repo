#!/bin/bash
#
# codespace-openvpn.sh
#
# نسخه‌ی مخصوص تست داخل GitHub Codespaces / دواِ‌کانتینرها.
# این اسکریپت:
#   1) بررسی می‌کند /dev/net/tun و قابلیت NET_ADMIN در دسترس باشد
#   2) OpenVPN را بدون نیاز به systemd بالا می‌آورد
#   3) با ngrok یک تونل عمومی TCP به پورت OpenVPN می‌سازد
#   4) فایل .ovpn نهایی را با آدرس عمومی ngrok می‌سازد و در ترمینال چاپ می‌کند
#
# هشدار مهم:
#   این راه‌اندازی فقط برای تست موقت مناسب است، نه استفاده‌ی دائمی.
#   با هر بار توقف/rebuild این Codespace، همه‌چیز از بین می‌رود و
#   آدرس عمومی ngrok هم عوض می‌شود؛ باید دوباره اسکریپت را اجرا کنی.
#   برای VPN دائمی و پایدار از فایل openvpn-install.sh روی یک VPS واقعی استفاده کن.

set -euo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m خط ${LINENO}: دستور \"${BASH_COMMAND}\" شکست خورد." 1>&2' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" 1>&2; }

EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_CONF="/etc/openvpn/server/server.conf"
CLIENT_DIR="${HOME}/openvpn-clients"
PORT=1194

# ------------------------- بررسی روت -------------------------
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "با sudo اجرا کن: sudo bash $0"
        exit 1
    fi
}

# ------------------------- بررسی دستگاه TUN و قابلیت NET_ADMIN -------------------------
check_tun_and_net_admin() {
    info "بررسی دستگاه /dev/net/tun ..."
    if [[ ! -c /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 600 /dev/net/tun 2>/dev/null || true
    fi

    if [[ ! -c /dev/net/tun ]]; then
        err "دستگاه /dev/net/tun در دسترس نیست."
        print_devcontainer_help
        exit 1
    fi

    info "بررسی قابلیت NET_ADMIN (تست ساخت اینترفیس موقت) ..."
    if ! ip tuntap add dev cs-test-tun0 mode tun 2>/dev/null; then
        err "این کانتینر دسترسی NET_ADMIN ندارد؛ ساخت اینترفیس شبکه ممکن نیست."
        print_devcontainer_help
        exit 1
    fi
    ip tuntap del dev cs-test-tun0 mode tun 2>/dev/null || true
    ok "TUN و NET_ADMIN در دسترس هستند."
}

print_devcontainer_help() {
    echo ""
    warn "راه‌حل: فایل .devcontainer/devcontainer.json را در ریشه‌ی ریپو بساز/ویرایش کن و این خطوط را اضافه کن:"
    echo ""
    cat <<'EOF'
{
  "name": "openvpn-codespace",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--device=/dev/net/tun"
  ]
}
EOF
    echo ""
    warn "سپس: Command Palette (Ctrl+Shift+P) > 'Codespaces: Rebuild Container' را بزن و بعد این اسکریپت را دوباره اجرا کن."
}

# ------------------------- نصب پکیج‌ها -------------------------
install_packages() {
    info "نصب OpenVPN, Easy-RSA, iptables ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openvpn easy-rsa iptables curl gnupg >/dev/null
    ok "پکیج‌ها نصب شدند."
}

# ------------------------- ساخت PKI -------------------------
setup_pki() {
    info "ساخت CA و گواهی‌های سرور ..."
    mkdir -p /etc/openvpn/server
    mkdir -p "$EASYRSA_DIR"
    cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR"/ 2>/dev/null || true

    cd "$EASYRSA_DIR"
    ./easyrsa init-pki
    echo "ca" | ./easyrsa build-ca nopass
    ./easyrsa gen-req server nopass
    echo "yes" | ./easyrsa sign-req server server
    ./easyrsa gen-dh
    openvpn --genkey secret /etc/openvpn/server/tc.key

    cp pki/ca.crt /etc/openvpn/server/
    cp pki/issued/server.crt /etc/openvpn/server/
    cp pki/private/server.key /etc/openvpn/server/
    cp pki/dh.pem /etc/openvpn/server/
    ok "PKI ساخته شد."
}

# ------------------------- نوشتن کانفیگ سرور -------------------------
write_server_conf() {
    info "نوشتن فایل پیکربندی سرور (proto tcp برای سازگاری با تونل ngrok) ..."
    NIC=$(ip route show default | awk '/default/ {print $5; exit}')
    echo "$NIC" > /etc/openvpn/server/nic.txt

    cat > "$SERVER_CONF" <<EOF
port ${PORT}
proto tcp-server
dev tun
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /etc/openvpn/server/ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt tc.key
cipher AES-256-GCM
auth SHA256
status /var/log/openvpn/status.log
verb 3
explicit-exit-notify 1
EOF
    mkdir -p /var/log/openvpn
    ok "server.conf آماده شد."
}

# ------------------------- ip_forward و iptables (بدون systemd) -------------------------
enable_forwarding_and_nat() {
    info "فعال‌سازی ip_forward و قوانین NAT ..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || warn "تنظیم ip_forward ممکن نشد (شاید از قبل فعال است)."

    NIC=$(cat /etc/openvpn/server/nic.txt)
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$NIC" -j MASQUERADE 2>/dev/null || warn "قانون NAT اعمال نشد."
    iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    ok "NAT پیکربندی شد."
}

# ------------------------- اجرای OpenVPN بدون systemd -------------------------
start_openvpn() {
    info "اجرای OpenVPN (بدون systemd، مستقیم در پس‌زمینه) ..."
    pkill -f "openvpn --config ${SERVER_CONF}" 2>/dev/null || true
    sleep 1
    openvpn --config "$SERVER_CONF" --daemon --writepid /var/run/openvpn-server.pid
    sleep 2
    if pgrep -f "openvpn --config ${SERVER_CONF}" > /dev/null; then
        ok "OpenVPN در حال اجراست (PID: $(cat /var/run/openvpn-server.pid))."
    else
        err "OpenVPN اجرا نشد. لاگ را بررسی کن: cat /var/log/openvpn/status.log"
        exit 1
    fi
}

# ------------------------- نصب و راه‌اندازی ngrok -------------------------
setup_ngrok() {
    if ! command -v ngrok &>/dev/null; then
        info "نصب ngrok ..."
        curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
        echo "deb https://ngrok-agent.s3.amazonaws.com bookworm main" | tee /etc/apt/sources.list.d/ngrok.list >/dev/null
        apt-get update -qq
        apt-get install -y -qq ngrok >/dev/null
        ok "ngrok نصب شد."
    fi

    if ! ngrok config check &>/dev/null; then
        echo ""
        warn "برای تونل عمومی به یک authtoken رایگان ngrok نیاز داری."
        warn "از این آدرس بگیر (ثبت‌نام رایگان با گیت‌هاب یا گوگل): https://dashboard.ngrok.com/get-started/your-authtoken"
        read -rp "authtoken ngrok را اینجا وارد کن: " NGROK_TOKEN < /dev/tty
        ngrok config add-authtoken "$NGROK_TOKEN"
    fi

    info "راه‌اندازی تونل عمومی TCP روی پورت ${PORT} ..."
    pkill -f "ngrok tcp" 2>/dev/null || true
    sleep 1
    nohup ngrok tcp "${PORT}" --log=stdout > /tmp/ngrok.log 2>&1 &
    sleep 5

    NGROK_URL=$(curl -s http://127.0.0.1:4040/api/tunnels \
        | grep -o '"public_url":"tcp://[^"]*"' \
        | head -n1 \
        | sed -E 's/"public_url":"tcp:\/\///; s/"//')

    if [[ -z "$NGROK_URL" ]]; then
        err "تونل ngrok برقرار نشد. لاگ را ببین: cat /tmp/ngrok.log"
        exit 1
    fi

    NGROK_HOST="${NGROK_URL%%:*}"
    NGROK_PORT="${NGROK_URL##*:}"
    ok "تونل عمومی آماده شد: ${NGROK_HOST}:${NGROK_PORT}"
}

# ------------------------- ساخت فایل کلاینت -------------------------
new_client() {
    local CLIENT="$1"
    mkdir -p "$CLIENT_DIR"

    cd "$EASYRSA_DIR"
    ./easyrsa gen-req "$CLIENT" nopass
    echo "yes" | ./easyrsa sign-req client "$CLIENT"

    local OVPN_FILE="${CLIENT_DIR}/${CLIENT}.ovpn"

    {
        echo "client"
        echo "dev tun"
        echo "proto tcp-client"
        echo "remote ${NGROK_HOST} ${NGROK_PORT}"
        echo "resolv-retry infinite"
        echo "nobind"
        echo "persist-key"
        echo "persist-tun"
        echo "remote-cert-tls server"
        echo "cipher AES-256-GCM"
        echo "auth SHA256"
        echo "verb 3"
        echo "<ca>"
        cat /etc/openvpn/server/ca.crt
        echo "</ca>"
        echo "<cert>"
        sed -ne '/BEGIN CERTIFICATE/,$ p' "${EASYRSA_DIR}/pki/issued/${CLIENT}.crt"
        echo "</cert>"
        echo "<key>"
        cat "${EASYRSA_DIR}/pki/private/${CLIENT}.key"
        echo "</key>"
        echo "<tls-crypt>"
        cat /etc/openvpn/server/tc.key
        echo "</tls-crypt>"
    } > "$OVPN_FILE"

    chmod 600 "$OVPN_FILE"

    echo ""
    ok "فایل اتصال کلاینت ساخته شد: ${OVPN_FILE}"
    echo ""
    echo -e "${YELLOW}===================== محتوای فایل ${CLIENT}.ovpn =====================${NC}"
    cat "$OVPN_FILE"
    echo -e "${YELLOW}=========================================================================${NC}"
}

# ------------------------- اجرای اصلی -------------------------
main() {
    check_root
    check_tun_and_net_admin
    install_packages
    setup_pki
    write_server_conf
    enable_forwarding_and_nat
    start_openvpn
    setup_ngrok
    new_client "client"

    echo ""
    ok "همه‌چیز آماده است! این آدرس عمومی موقتی توست:"
    echo "   ${NGROK_HOST}:${NGROK_PORT}  (TCP)"
    echo ""
    warn "توجه‌ها:"
    warn "  - این فقط برای تست موقت است. با متوقف‌شدن این Codespace یا فرآیند ngrok، اتصال قطع می‌شود."
    warn "  - هر بار که این Codespace را دوباره باز/rebuild کنی، باید این اسکریپت را دوباره اجرا کنی و آدرس/فایل .ovpn عوض می‌شود."
    warn "  - برای استفاده‌ی واقعی و پایدار، فایل openvpn-install.sh را روی یک VPS واقعی اجرا کن."
}

main
