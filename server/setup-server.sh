#!/bin/bash
# ==============================================================================
# VK-TURN-PROXY + WireGuard: Установка сервера
# ==============================================================================
#
# Что делает этот скрипт:
#   1. Ставит WireGuard
#   2. Генерирует ключи (сервер + клиент)
#   3. Настраивает WireGuard (wg0)
#   4. Ставит Go и собирает vk-turn-proxy server
#   5. Создаёт systemd-сервис для vk-turn-proxy
#   6. Настраивает файрвол и IP forwarding
#   7. Выводит конфиг для iOS-приложения
#
# Использование:
#   curl -sSL <url> | sudo bash
#   или:
#   chmod +x setup-server.sh && sudo ./setup-server.sh
#
# Требования:
#   - Ubuntu 20.04+ / Debian 11+
#   - Root доступ
#   - Публичный IP
#
# ==============================================================================

set -euo pipefail

# ========================= НАСТРОЙКИ =========================================
# Можно менять перед запуском

WG_PORT=51820                    # Порт WireGuard
WG_NETWORK="10.7.0"             # Сеть WireGuard (будет 10.7.0.0/24)
WG_SERVER_IP="${WG_NETWORK}.1"   # IP сервера в WG-сети
WG_CLIENT_IP="${WG_NETWORK}.2"   # IP клиента (iPhone) в WG-сети
TURN_PROXY_PORT=56000            # Порт vk-turn-proxy (принимает трафик от TURN)
DNS_SERVER="1.1.1.1"            # DNS для клиента
MTU=1280                         # MTU (меньше стандартного из-за оверхеда TURN+DTLS)

# ========================= ЦВЕТА =============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ========================= ПРОВЕРКИ ==========================================

if [[ $EUID -ne 0 ]]; then
    err "Запусти от root: sudo ./setup-server.sh"
fi

# Определяем публичный IP
SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com || curl -s4 api.ipify.org)
if [[ -z "$SERVER_IP" ]]; then
    err "Не удалось определить публичный IP"
fi
info "Публичный IP: $SERVER_IP"

# Определяем основной сетевой интерфейс
MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)
if [[ -z "$MAIN_IFACE" ]]; then
    err "Не удалось определить сетевой интерфейс"
fi
info "Сетевой интерфейс: $MAIN_IFACE"

# ========================= 1. УСТАНОВКА WIREGUARD ============================
info "Устанавливаю WireGuard..."

apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools iptables curl git > /dev/null 2>&1

ok "WireGuard установлен"

# ========================= 2. ГЕНЕРАЦИЯ КЛЮЧЕЙ ==============================
info "Генерирую ключи..."

# Директория для ключей
mkdir -p /etc/wireguard/keys
chmod 700 /etc/wireguard/keys

# Серверные ключи
wg genkey | tee /etc/wireguard/keys/server_private > /dev/null
cat /etc/wireguard/keys/server_private | wg pubkey > /etc/wireguard/keys/server_public

# Клиентские ключи (для iPhone)
wg genkey | tee /etc/wireguard/keys/client_private > /dev/null
cat /etc/wireguard/keys/client_private | wg pubkey > /etc/wireguard/keys/client_public

chmod 600 /etc/wireguard/keys/*

SERVER_PRIVKEY=$(cat /etc/wireguard/keys/server_private)
SERVER_PUBKEY=$(cat /etc/wireguard/keys/server_public)
CLIENT_PRIVKEY=$(cat /etc/wireguard/keys/client_private)
CLIENT_PUBKEY=$(cat /etc/wireguard/keys/client_public)

ok "Ключи сгенерированы"

# ========================= 3. НАСТРОЙКА WIREGUARD ============================
info "Настраиваю WireGuard..."

cat > /etc/wireguard/wg0.conf << EOF
# ==============================================================================
# WireGuard Server Config
# Создан автоматически: $(date)
# ==============================================================================

[Interface]
# Приватный ключ сервера
PrivateKey = ${SERVER_PRIVKEY}

# IP сервера в VPN-сети
Address = ${WG_SERVER_IP}/24

# Порт для входящих подключений
# ВАЖНО: клиент НЕ подключается напрямую к этому порту.
# Трафик идёт: iPhone -> VK TURN -> vk-turn-proxy:${TURN_PROXY_PORT} -> WG:${WG_PORT}
ListenPort = ${WG_PORT}

# NAT: позволяет VPN-клиентам выходить в интернет через сервер
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${MAIN_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${MAIN_IFACE} -j MASQUERADE

# --- Клиент: iPhone ---
[Peer]
# Публичный ключ клиента
PublicKey = ${CLIENT_PUBKEY}

# Какие IP разрешены от этого клиента
AllowedIPs = ${WG_CLIENT_IP}/32
EOF

chmod 600 /etc/wireguard/wg0.conf

ok "WireGuard настроен: /etc/wireguard/wg0.conf"

# ========================= 4. IP FORWARDING ==================================
info "Включаю IP forwarding..."

# Включаем сейчас
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Включаем навсегда
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

ok "IP forwarding включён"

# ========================= 5. УСТАНОВКА GO + СБОРКА VK-TURN-PROXY ===========
info "Устанавливаю Go..."

# Проверяем, есть ли уже Go
GO_VERSION="1.23.4"
if command -v go &> /dev/null; then
    CURRENT_GO=$(go version | awk '{print $3}' | tr -d 'go')
    info "Go уже установлен: $CURRENT_GO"
else
    # Скачиваем и ставим Go
    GO_ARCH="amd64"
    if [[ $(uname -m) == "aarch64" ]]; then
        GO_ARCH="arm64"
    fi

    cd /tmp
    curl -sLO "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    rm "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

    # Добавляем в PATH
    export PATH=$PATH:/usr/local/go/bin
    if ! grep -q '/usr/local/go/bin' /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi

    ok "Go ${GO_VERSION} установлен"
fi

export PATH=$PATH:/usr/local/go/bin

info "Собираю vk-turn-proxy server..."

BUILD_DIR="/tmp/vk-turn-proxy-build"
rm -rf "$BUILD_DIR"
git clone --depth 1 https://github.com/cacggghp/vk-turn-proxy "$BUILD_DIR" 2>/dev/null

cd "$BUILD_DIR"

# Собираем сервер
# Примечание: если go.mod требует слишком новую версию Go,
# пробуем с флагом GOTOOLCHAIN
export GOTOOLCHAIN=auto
go build -o /usr/local/bin/vk-turn-server ./server/

chmod +x /usr/local/bin/vk-turn-server

# Чистим
rm -rf "$BUILD_DIR"

ok "vk-turn-proxy server собран: /usr/local/bin/vk-turn-server"

# ========================= 6. SYSTEMD СЕРВИС ДЛЯ VK-TURN-PROXY =============
info "Создаю systemd сервис..."

cat > /etc/systemd/system/vk-turn-proxy.service << EOF
# ==============================================================================
# vk-turn-proxy server
# ==============================================================================
# Принимает трафик от VK TURN серверов и пересылает в WireGuard.
#
# Схема трафика:
#   iPhone -> VK TURN (белый список) -> этот сервер:${TURN_PROXY_PORT} -> WG:${WG_PORT}
#
# Управление:
#   systemctl start vk-turn-proxy     # запустить
#   systemctl stop vk-turn-proxy      # остановить
#   systemctl restart vk-turn-proxy   # перезапустить
#   journalctl -u vk-turn-proxy -f    # смотреть логи
# ==============================================================================

[Unit]
Description=VK TURN Proxy Server
Documentation=https://github.com/cacggghp/vk-turn-proxy
After=network.target wg-quick@wg0.service
Wants=wg-quick@wg0.service

[Service]
Type=simple

# Слушаем на ${TURN_PROXY_PORT} (UDP) — сюда приходит трафик от TURN-серверов ВК
# Пересылаем в WireGuard на localhost:${WG_PORT}
ExecStart=/usr/local/bin/vk-turn-server -listen 0.0.0.0:${TURN_PROXY_PORT} -connect 127.0.0.1:${WG_PORT}

Restart=always
RestartSec=5

# Безопасность
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

ok "Systemd сервис создан"

# ========================= 7. ФАЙРВОЛ =======================================
info "Настраиваю файрвол..."

# Открываем порт vk-turn-proxy (UDP) — ЕДИНСТВЕННЫЙ порт, который нужен снаружи
# WireGuard порт НЕ открываем — к нему подключаются только через vk-turn-proxy
if command -v ufw &> /dev/null; then
    ufw allow ${TURN_PROXY_PORT}/udp comment "vk-turn-proxy" > /dev/null 2>&1
    ufw allow 22/tcp comment "SSH" > /dev/null 2>&1

    # Убеждаемся что UFW включён
    echo "y" | ufw enable > /dev/null 2>&1
    ok "UFW: открыт порт ${TURN_PROXY_PORT}/udp"
else
    # Без UFW — используем iptables напрямую
    iptables -A INPUT -p udp --dport ${TURN_PROXY_PORT} -j ACCEPT
    ok "iptables: открыт порт ${TURN_PROXY_PORT}/udp"
fi

# ========================= 8. ЗАПУСК =========================================
info "Запускаю сервисы..."

# WireGuard
systemctl enable wg-quick@wg0 > /dev/null 2>&1
systemctl start wg-quick@wg0 2>/dev/null || {
    # Если WG уже запущен, перезапускаем
    systemctl restart wg-quick@wg0
}
ok "WireGuard запущен"

# vk-turn-proxy
systemctl enable vk-turn-proxy > /dev/null 2>&1
systemctl start vk-turn-proxy
ok "vk-turn-proxy запущен"

# ========================= 9. ПРОВЕРКА ======================================
info "Проверяю сервисы..."

sleep 2

if systemctl is-active --quiet wg-quick@wg0; then
    ok "WireGuard: работает"
else
    warn "WireGuard: проблема! Смотри: journalctl -u wg-quick@wg0"
fi

if systemctl is-active --quiet vk-turn-proxy; then
    ok "vk-turn-proxy: работает"
else
    warn "vk-turn-proxy: проблема! Смотри: journalctl -u vk-turn-proxy"
fi

# Проверяем что wg0 интерфейс поднялся
if ip link show wg0 &>/dev/null; then
    ok "Интерфейс wg0: активен"
else
    warn "Интерфейс wg0: не найден!"
fi

# ========================= СОХРАНЯЕМ КОНФИГ КЛИЕНТА ==========================

CLIENT_CONFIG_DIR="/etc/wireguard/client-config"
mkdir -p "$CLIENT_CONFIG_DIR"

# Конфиг для iOS приложения (JSON)
cat > "${CLIENT_CONFIG_DIR}/ios-config.json" << EOF
{
    "_comment": "Конфиг для iOS-приложения VKTurnVPN",
    "_date": "$(date -Iseconds)",

    "peerAddr": "${SERVER_IP}:${TURN_PROXY_PORT}",
    "wgPrivateKey": "${CLIENT_PRIVKEY}",
    "wgPublicKey": "${SERVER_PUBKEY}",
    "wgAddress": "${WG_CLIENT_IP}/32",
    "wgDNS": "${DNS_SERVER}",
    "mtu": ${MTU},

    "_instructions": [
        "1. Создай ВК-звонок: https://vk.com/call -> Начать звонок -> Скопировать ссылку",
        "2. НЕ нажимай 'Завершить звонок для всех' (ссылка будет работать вечно)",
        "3. Вставь VK-ссылку и эти данные в iOS-приложение",
        "4. Подключайся!"
    ]
}
EOF

# Обычный WireGuard конфиг (для тестирования без TURN)
cat > "${CLIENT_CONFIG_DIR}/client-wg0.conf" << EOF
# ==============================================================================
# WireGuard Client Config (для тестирования БЕЗ TURN)
# ==============================================================================
# Этот конфиг для прямого подключения к WireGuard (без vk-turn-proxy).
# Работает только если порт ${WG_PORT} доступен напрямую.
# Для подключения через TURN используй iOS-приложение.
# ==============================================================================

[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${WG_CLIENT_IP}/32
DNS = ${DNS_SERVER}
MTU = ${MTU}

[Peer]
PublicKey = ${SERVER_PUBKEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:${WG_PORT}
PersistentKeepalive = 25
EOF

chmod 600 "${CLIENT_CONFIG_DIR}"/*

# ========================= ВЫВОД ============================================

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}  УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo ""
echo -e "${BLUE}Сервер:${NC}"
echo "  IP:                  ${SERVER_IP}"
echo "  WireGuard порт:      ${WG_PORT} (только localhost)"
echo "  vk-turn-proxy порт:  ${TURN_PROXY_PORT} (UDP, открыт наружу)"
echo ""
echo -e "${BLUE}Схема работы:${NC}"
echo "  iPhone -> VK TURN сервер -> ${SERVER_IP}:${TURN_PROXY_PORT} -> WireGuard"
echo ""
echo -e "${YELLOW}======================================================================${NC}"
echo -e "${YELLOW}  ДАННЫЕ ДЛЯ iOS ПРИЛОЖЕНИЯ (СОХРАНИ!)${NC}"
echo -e "${YELLOW}======================================================================${NC}"
echo ""
echo "  Адрес VPS:           ${SERVER_IP}:${TURN_PROXY_PORT}"
echo "  WG Private Key:      ${CLIENT_PRIVKEY}"
echo "  WG Server Public Key:${SERVER_PUBKEY}"
echo "  Client IP:           ${WG_CLIENT_IP}"
echo "  DNS:                 ${DNS_SERVER}"
echo "  MTU:                 ${MTU}"
echo ""
echo -e "${YELLOW}======================================================================${NC}"
echo -e "${YELLOW}  СЛЕДУЮЩИЕ ШАГИ${NC}"
echo -e "${YELLOW}======================================================================${NC}"
echo ""
echo "  1. Создай ВК-звонок:"
echo "     - Зайди на https://vk.com/call"
echo "     - Нажми 'Начать звонок'"
echo "     - Скопируй ссылку (https://vk.com/call/join/...)"
echo "     - НЕ нажимай 'Завершить звонок для всех'"
echo ""
echo "  2. Собери iOS-приложение (на Mac):"
echo "     cd vk-turn-ios && make ios"
echo ""
echo "  3. Введи данные выше + VK-ссылку в приложение"
echo ""
echo -e "${BLUE}Конфиги сохранены:${NC}"
echo "  iOS JSON:      ${CLIENT_CONFIG_DIR}/ios-config.json"
echo "  WG конфиг:     ${CLIENT_CONFIG_DIR}/client-wg0.conf"
echo ""
echo -e "${BLUE}Управление:${NC}"
echo "  systemctl status vk-turn-proxy    # статус прокси"
echo "  systemctl status wg-quick@wg0     # статус WireGuard"
echo "  journalctl -u vk-turn-proxy -f    # логи прокси"
echo "  wg show                           # состояние WireGuard"
echo ""
