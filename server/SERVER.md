# Серверная часть VK Turn VPN

## Компоненты

| Компонент | Порт | Описание |
|---|---|---|
| **WireGuard** (xray inbound) | 51820/udp | Принимает WG-пакеты от vk-turn-proxy |
| **vk-turn-proxy server** | 56000/udp | Принимает DTLS от VK TURN, пересылает в WG |

## Схема трафика

```
iPhone → VK TURN сервер → VPS:56000 (vk-turn-proxy) → WG:51820 (xray) → интернет
```

## Установка

### Вариант 1: С 3x-ui (xray)

Если уже есть 3x-ui, добавь WireGuard inbound:

```bash
# Сгенерируй ключи
/usr/local/x-ui/bin/xray-linux-amd64 x25519
```

Добавь через панель или в БД:
- Protocol: `wireguard`
- Port: `51820`
- Settings: `{"mtu":1280,"secretKey":"<СЕРВЕРНЫЙ_ПРИВАТНЫЙ>","peers":[{"publicKey":"<КЛИЕНТСКИЙ_ПУБЛИЧНЫЙ>","allowedIPs":["10.7.0.2/32"]}],"kernelMode":false}`

### Вариант 2: Системный WireGuard

```bash
sudo ./setup-server.sh
```

### Установка vk-turn-proxy server

```bash
# Собрать
git clone https://github.com/cacggghp/vk-turn-proxy /tmp/vk-turn-build
cd /tmp/vk-turn-build
go build -o /usr/local/bin/vk-turn-server ./server/
rm -rf /tmp/vk-turn-build

# Systemd сервис
sudo tee /etc/systemd/system/vk-turn-proxy.service << 'EOF'
[Unit]
Description=VK TURN Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vk-turn-server -listen 0.0.0.0:56000 -connect 127.0.0.1:51820
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now vk-turn-proxy
```

### Файрвол

```bash
sudo ufw allow 56000/udp comment "vk-turn-proxy"
```

> Порт 51820 НЕ открывай — он доступен только через vk-turn-proxy.

## Управление

```bash
sudo systemctl status vk-turn-proxy    # статус
sudo systemctl restart vk-turn-proxy   # перезапуск
sudo journalctl -u vk-turn-proxy -f    # логи
ss -ulnp | grep -E '(51820|56000)'     # проверка портов
```

## Добавление клиентов

1. Сгенерируй ключи: `xray x25519`
2. Добавь peer в WireGuard inbound (публичный ключ клиента + его IP в VPN-сети)
3. Отдай клиенту: приватный ключ + публичный ключ сервера + адрес VPS:56000
