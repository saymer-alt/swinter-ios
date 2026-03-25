# Клиентские конфиги

## Что нужно для подключения

1. **VK-ссылка** — создай ВК-звонок: https://vk.com/call → начать → скопировать ссылку
   - НЕ нажимай "Завершить звонок для всех" — ссылка будет работать вечно
2. **WireGuard ключи** — сгенерируй на сервере через `xray x25519` или `wg genkey`
3. **Адрес VPS** — IP:порт vk-turn-proxy сервера (обычно :56000)

## Шаблон WireGuard конфига (для Android с vk-turn-proxy)

```ini
[Interface]
PrivateKey = <КЛИЕНТСКИЙ_ПРИВАТНЫЙ_КЛЮЧ>
Address = 10.7.0.X/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = <СЕРВЕРНЫЙ_ПУБЛИЧНЫЙ_КЛЮЧ>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:9000
PersistentKeepalive = 25
```

> Endpoint `127.0.0.1:9000` — это адрес локального vk-turn-proxy клиента.
> Трафик идёт: WireGuard → localhost:9000 → VK TURN → VPS

## Инструкция для Android

1. Скачай [WireGuard](https://play.google.com/store/apps/details?id=com.wireguard.android) + [vk-turn-proxy-android](https://github.com/MYSOREZ/vk-turn-proxy-android)
2. Импортируй WireGuard конфиг
3. **ВАЖНО:** Добавь vk-turn-proxy в исключения WireGuard
4. В vk-turn-proxy укажи:
   - Peer: `<IP_VPS>:56000`
   - VK ссылка: (твоя)
   - Listen: `127.0.0.1:9000`
5. Запусти proxy → дождись "DTLS connection established" → включи WireGuard

## Генерация ключей

```bash
# На сервере с xray:
/usr/local/x-ui/bin/xray-linux-amd64 x25519
# PrivateKey = серверный приватный (в xray inbound)
# Password = серверный публичный (в клиентский конфиг как PublicKey)

# Для каждого клиента:
/usr/local/x-ui/bin/xray-linux-amd64 x25519
# PrivateKey = клиентский приватный (в клиентский конфиг)
# Password = клиентский публичный (в xray inbound peers)
```
