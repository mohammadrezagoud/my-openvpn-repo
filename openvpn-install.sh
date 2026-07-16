#!/bin/bash
#
# openvpn-install.sh
#
# یک اسکریپت خودکار برای نصب، پیکربندی و مدیریت OpenVPN Server
# پشتیبانی از: Ubuntu 18.04+, Debian 10+, CentOS/Rocky/AlmaLinux 8+, Fedora
#
# استفاده:
#   sudo bash openvpn-install.sh
#
# نویسنده: ساخته شده برای مخزن گیت‌هاب شخصی شما
# لایسنس: MIT

set -euo pipefail

# ------------------------- رنگ‌ها برای خروجی زیباتر -------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" 1>&2; }

# ------------------------- مسیرها و متغیرهای پایه -------------------------
EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_CONF="/etc/openvpn/server/server.conf"
CLIENT_DIR="${HOME}/openvpn-clients"
IPTABLES_SVC="/etc/systemd/system/openvpn-iptables.service"
IPTABLES_SCRIPT="/etc/openvpn/iptables-openvpn.sh"

# ------------------------- بررسی دسترسی روت -------------------------
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "این اسکریپت باید با دسترسی روت اجرا شود. مثال: sudo bash $0"
        exit 1
    fi
}

# ------------------------- تشخیص سیستم‌عامل -------------------------
detect_os() {
    if [[ -e /etc/debian_version ]]; then
        OS="debian"
        GROUPNAME="nogroup"
        RCLOCAL="/etc/rc.local"
        if grep -qs "ubuntu" /etc/os-release; then
            OS="ubuntu"
        fi
    elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release || -e /etc/redhat-release ]]; then
        OS="centos"
        GROUPNAME="nobody"
        RCLOCAL="/etc/rc.d/rc.local"
    elif [[ -e /etc/fedora-release ]]; then
        OS="fedora"
        GROUPNAME="nobody"
    else
        err "سیستم‌عامل شما پشتیبانی نمی‌شود. این اسکریپت برای Ubuntu, Debian, CentOS/Rocky/AlmaLinux و Fedora ساخته شده."
        exit 1
    fi
}

# ------------------------- نصب پکیج‌ها -------------------------
install_packages() {
    info "در حال نصب OpenVPN و Easy-RSA ..."
    if [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        apt-get update
        apt-get install -y openvpn iptables openssl ca-certificates curl easy-rsa
    else
        # CentOS / Rocky / Alma / Fedora
        if [[ "$OS" == "fedora" ]]; then
            dnf install -y openvpn iptables openssl ca-certificates curl easy-rsa
        else
            if ! command -v dnf &>/dev/null; then
                yum install -y epel-release
                yum install -y openvpn iptables openssl ca-certificates curl easy-rsa
            else
                dnf install -y epel-release
                dnf install -y openvpn iptables openssl ca-certificates curl easy-rsa
            fi
        fi
    fi
    ok "پکیج‌ها با موفقیت نصب شدند."
}

# ------------------------- گرفتن اطلاعات از کاربر -------------------------
ask_questions() {
    echo ""
    info "پیکربندی سرور OpenVPN"
    echo ""

    # آی‌پی عمومی سرور
    DEFAULT_IP=$(curl -s -4 ifconfig.co || curl -s -4 icanhazip.com || hostname -I | awk '{print $1}')
    read -rp "آدرس IP عمومی سرور [${DEFAULT_IP}]: " PUBLIC_IP
    PUBLIC_IP=${PUBLIC_IP:-$DEFAULT_IP}

    # پروتکل
    echo ""
    echo "پروتکل را انتخاب کنید:"
    echo "   1) UDP (پیشنهاد می‌شود - سریع‌تر)"
    echo "   2) TCP"
    read -rp "انتخاب [1]: " PROTO_CHOICE
    PROTO_CHOICE=${PROTO_CHOICE:-1}
    if [[ "$PROTO_CHOICE" == "2" ]]; then
        PROTOCOL="tcp"
    else
        PROTOCOL="udp"
    fi

    # پورت
    read -rp "پورت OpenVPN [1194]: " PORT
    PORT=${PORT:-1194}

    # DNS برای کلاینت‌ها
    echo ""
    echo "سرور DNS برای کلاینت‌ها:"
    echo "   1) Cloudflare (1.1.1.1)"
    echo "   2) Google (8.8.8.8)"
    echo "   3) Quad9 (9.9.9.9)"
    read -rp "انتخاب [1]: " DNS_CHOICE
    DNS_CHOICE=${DNS_CHOICE:-1}
    case "$DNS_CHOICE" in
        2) DNS1="8.8.8.8"; DNS2="8.8.4.4" ;;
        3) DNS1="9.9.9.9"; DNS2="149.112.112.112" ;;
        *) DNS1="1.1.1.1"; DNS2="1.0.0.1" ;;
    esac

    # نام اولین کلاینت
    echo ""
    read -rp "نام کلاینت اول (بدون فاصله) [client]: " CLIENT_NAME
    CLIENT_NAME=${CLIENT_NAME:-client}

    echo ""
    ok "تنظیمات دریافت شد. شروع نصب ..."
    sleep 1
}

# ------------------------- ساخت PKI با Easy-RSA -------------------------
setup_pki() {
    info "در حال ساخت CA و گواهی‌های سرور ..."
    mkdir -p /etc/openvpn/server
    mkdir -p "$EASYRSA_DIR"

    EASYRSA_BIN=$(command -v easyrsa || echo "/usr/share/easy-rsa/easyrsa")
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

    ok "PKI با موفقیت ساخته شد."
}

# ------------------------- نوشتن فایل کانفیگ سرور -------------------------
write_server_conf() {
    info "در حال نوشتن فایل پیکربندی سرور ..."

    # انتخاب اینترفیس شبکه پیش‌فرض برای NAT
    NIC=$(ip route show default | awk '/default/ {print $5; exit}')

    cat > "$SERVER_CONF" <<EOF
port ${PORT}
proto ${PROTOCOL}
dev tun
user nobody
group ${GROUPNAME}
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /etc/openvpn/server/ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS1}"
push "dhcp-option DNS ${DNS2}"
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt tc.key
cipher AES-256-GCM
auth SHA256
dh dh.pem
status /var/log/openvpn/status.log
verb 3
explicit-exit-notify 1
EOF

    mkdir -p /var/log/openvpn
    echo "$NIC" > /etc/openvpn/server/nic.txt

    ok "فایل server.conf آماده شد."
}

# ------------------------- فعال‌سازی IP forwarding -------------------------
enable_forwarding() {
    info "فعال‌سازی IP forwarding ..."
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
    sysctl --system > /dev/null
    ok "IP forwarding فعال شد."
}

# ------------------------- قوانین iptables برای NAT -------------------------
setup_iptables() {
    info "پیکربندی قوانین فایروال (NAT) ..."
    NIC=$(cat /etc/openvpn/server/nic.txt)

    cat > "$IPTABLES_SCRIPT" <<EOF
#!/bin/bash
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${NIC} -j MASQUERADE
iptables -I INPUT -p ${PROTOCOL} --dport ${PORT} -j ACCEPT
iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
    chmod +x "$IPTABLES_SCRIPT"

    cat > "$IPTABLES_SVC" <<EOF
[Unit]
Description=iptables rules for OpenVPN
Before=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${IPTABLES_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now openvpn-iptables.service

    ok "قوانین NAT اعمال شد."
}

# ------------------------- راه‌اندازی سرویس OpenVPN -------------------------
start_openvpn_service() {
    info "راه‌اندازی سرویس OpenVPN ..."
    systemctl enable --now openvpn-server@server.service
    sleep 2
    if systemctl is-active --quiet openvpn-server@server.service; then
        ok "سرویس OpenVPN با موفقیت اجرا شد."
    else
        err "سرویس OpenVPN اجرا نشد. لاگ را بررسی کنید: journalctl -u openvpn-server@server -e"
        exit 1
    fi
}

# ------------------------- ساخت کلاینت جدید و خروجی .ovpn -------------------------
new_client() {
    local CLIENT="$1"
    mkdir -p "$CLIENT_DIR"

    cd "$EASYRSA_DIR"
    ./easyrsa gen-req "$CLIENT" nopass
    echo "yes" | ./easyrsa sign-req client "$CLIENT"

    local OVPN_FILE="${CLIENT_DIR}/${CLIENT}.ovpn"
    local SERVER_IP
    SERVER_IP=$(cat /etc/openvpn/server/public-ip.txt 2>/dev/null || echo "${PUBLIC_IP:-YOUR_SERVER_IP}")
    local SERVER_PORT
    SERVER_PORT=$(grep '^port ' "$SERVER_CONF" | awk '{print $2}')
    local SERVER_PROTO
    SERVER_PROTO=$(grep '^proto ' "$SERVER_CONF" | awk '{print $2}')

    {
        echo "client"
        echo "dev tun"
        echo "proto ${SERVER_PROTO}"
        echo "remote ${SERVER_IP} ${SERVER_PORT}"
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
    echo ""
    info "این محتوا را کپی کرده و در یک فایل با پسوند .ovpn ذخیره کنید،"
    info "یا مستقیماً فایل بالا را با اسکنر QR کد اپ OpenVPN Connect وارد کنید،"
    info "یا با دستور زیر آن را از سرور دانلود کنید (SCP):"
    echo ""
    echo "   scp root@${SERVER_IP}:${OVPN_FILE} ."
    echo ""
}

# ------------------------- حذف یک کلاینت -------------------------
revoke_client() {
    local CLIENT="$1"
    cd "$EASYRSA_DIR"
    echo "yes" | ./easyrsa revoke "$CLIENT"
    ./easyrsa gen-crl
    cp pki/crl.pem /etc/openvpn/server/
    systemctl restart openvpn-server@server.service
    rm -f "${CLIENT_DIR}/${CLIENT}.ovpn"
    ok "کلاینت ${CLIENT} حذف و دسترسی‌اش لغو شد."
}

# ------------------------- حذف کامل OpenVPN -------------------------
uninstall_all() {
    warn "در حال حذف کامل OpenVPN و تمام تنظیمات ..."
    systemctl disable --now openvpn-server@server.service 2>/dev/null || true
    systemctl disable --now openvpn-iptables.service 2>/dev/null || true
    rm -rf /etc/openvpn
    rm -f "$IPTABLES_SVC"
    rm -f /etc/sysctl.d/99-openvpn-forward.conf
    systemctl daemon-reload
    if [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        apt-get remove -y openvpn
    fi
    ok "OpenVPN به‌طور کامل حذف شد."
}

# ------------------------- منوی اصلی -------------------------
main_menu() {
    if [[ -e "$SERVER_CONF" ]]; then
        echo ""
        echo "OpenVPN از قبل نصب شده است. چه کاری می‌خواهید انجام دهید؟"
        echo "   1) اضافه کردن کلاینت جدید"
        echo "   2) حذف (لغو دسترسی) یک کلاینت"
        echo "   3) حذف کامل OpenVPN"
        echo "   4) خروج"
        read -rp "انتخاب: " MENU_OPTION
        case "$MENU_OPTION" in
            1)
                read -rp "نام کلاینت جدید: " NEW_CLIENT
                new_client "$NEW_CLIENT"
                ;;
            2)
                read -rp "نام کلاینتی که باید حذف شود: " DEL_CLIENT
                revoke_client "$DEL_CLIENT"
                ;;
            3)
                read -rp "آیا مطمئن هستید؟ (yes/no): " CONFIRM
                [[ "$CONFIRM" == "yes" ]] && uninstall_all
                ;;
            *)
                exit 0
                ;;
        esac
        exit 0
    fi
}

# ------------------------- اجرای اصلی اسکریپت -------------------------
check_root
detect_os
main_menu   # اگر از قبل نصب بود، اینجا خارج می‌شود

ask_questions
echo "$PUBLIC_IP" > /tmp/openvpn-public-ip.txt
install_packages
setup_pki
mkdir -p /etc/openvpn/server
echo "$PUBLIC_IP" > /etc/openvpn/server/public-ip.txt
write_server_conf
enable_forwarding
setup_iptables
start_openvpn_service
new_client "$CLIENT_NAME"

echo ""
ok "نصب OpenVPN Server با موفقیت به پایان رسید!"
info "سرور شما در حال اجرا روی ${PUBLIC_IP}:${PORT}/${PROTOCOL} است."
info "برای افزودن کلاینت‌های بیشتر، دوباره این اسکریپت را اجرا کنید: sudo bash $0"
