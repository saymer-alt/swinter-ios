# VK Turn VPN

> **Disclaimer:** Этот проект навайбкоден с помощью Claude Code. Я не программист, но всё протестировано руками — работает. К любой помощи и PR'ам открыт!

iOS-приложение для обхода белых списков через TURN-серверы ВК-звонков.

## Как это работает

```
iPhone                    VK TURN серверы           VPS
┌──────────┐             ┌───────────────┐         ┌──────────────────┐
│ WireGuard│── DTLS ──→ │  TURN relay   │── UDP →│ vk-turn-proxy    │
│ + TURN   │  через TCP  │  (в белом     │         │   ↓              │
│ proxy    │  или UDP     │   списке!)    │         │ WireGuard (xray) │
│          │             │               │         │   ↓              │
│          │             │               │         │ Интернет         │
└──────────┘             └───────────────┘         └──────────────────┘
```

Трафик шифруется WireGuard, оборачивается в DTLS и отправляется через TURN-серверы ВК (которые в белом списке оператора). TURN-сервер думает что это обычный ВК-звонок и пересылает пакеты на VPS. На VPS `vk-turn-proxy` снимает обёртку и передаёт в WireGuard.

## Структура проекта

```
vk-turn-ios/
├── ios/                    # iOS-приложение (SwiftUI + Network Extension)
│   ├── project.yml         # XcodeGen спецификация
│   └── VKTurnVPN/
│       ├── App/            # Основное приложение (UI, VPN Manager)
│       ├── Tunnel/         # Network Extension (PacketTunnelProvider)
│       └── Shared/         # Общий код (VPNConfig)
├── golib/                  # Go-библиотека (gomobile → xcframework)
│   └── vpnlib/
│       ├── vpnlib.go       # Экспорты: StartVPN, StopVPN, ResolveConfig
│       ├── turn.go         # TURN-прокси + VK API для получения кредов
│       └── tunwrap.go      # Кастомный TUN для iOS NE (без ioctl)
├── server/                 # Серверная часть
│   ├── setup-server.sh     # Скрипт автоустановки
│   └── SERVER.md           # Документация сервера
├── configs/                # Шаблоны клиентских конфигов
│   └── CONFIGS.md          # Документация конфигов
└── Makefile                # Сборка всего проекта
```

## Требования

### Для сборки iOS-приложения (Mac)
- macOS с Xcode 15+
- Go 1.23+ (`brew install go`)
- gomobile (`go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`)
- xcodegen (`brew install xcodegen`)
- Apple Developer Account (для Network Extension entitlement)

### Для сервера (VPS)
- Ubuntu 20.04+ / Debian 11+
- 3x-ui (xray panel) ИЛИ WireGuard

## Быстрый старт

### 1. Настройка сервера

```bash
# Если есть 3x-ui — добавь WireGuard inbound через панель
# Если нет — запусти скрипт:
sudo ./server/setup-server.sh
```

Затем установи и запусти vk-turn-proxy server:

```bash
# Собрать из исходников
git clone https://github.com/cacggghp/vk-turn-proxy /tmp/vk-turn-proxy
cd /tmp/vk-turn-proxy && go build -o /usr/local/bin/vk-turn-server ./server/

# Запустить (systemd)
# Слушает на :56000, пересылает в WireGuard на :51820
vk-turn-server -listen 0.0.0.0:56000 -connect 127.0.0.1:51820
```

### 2. Сборка iOS-приложения

```bash
# Установить зависимости
make setup

# Собрать Go-библиотеку (xcframework)
make golib

# Сгенерировать Xcode-проект
make project

# Открыть в Xcode
make xcode
```

В Xcode:
1. Выбери Team в Signing & Capabilities (оба таргета)
2. Подключи iPhone
3. Build & Run

### 3. Настройка приложения

1. Создай ВК-звонок: https://vk.com/call → начать → скопировать ссылку
2. В настройках приложения (⚙️):
   - Вставь VK-ссылку
   - Нажми "Вставить конфиг сервера" или введи вручную:
     - Адрес VPS: `IP:56000`
     - WG Private Key: ключ клиента
     - WG Public Key: ключ сервера
     - Client IP: `10.7.0.2/32`
     - DNS: `1.1.1.1`
3. Нажми "Подключиться"

### 4. Для Android

Используй [vk-turn-proxy-android](https://github.com/MYSOREZ/vk-turn-proxy-android) + стандартный WireGuard.

## Особенности

- **Liquid glass UI** — анимированный фон, стеклянные карточки, пульсирующий орб
- **Автоматический ретрай** — 5 попыток получения TURN-кредов с VK API
- **Предзагрузка кредов** — VK API вызывается из основного приложения, не из NE
- **Кастомный TUN** — обход ограничения iOS NE sandbox (ioctl blocked)
- **UDP/TCP режим** — выбор транспорта для TURN-подключения

## Ограничения

- Скорость ~5-20 Мбит/с (ограничение VK TURN серверов)
- VK ссылка на звонок должна быть активной (не завершённой)
- На некоторых сетях VK API может возвращать "ip mismatch" — приложение автоматически повторяет

## На основе

Это iOS-обёртка над [vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy) — проектом для проброса WireGuard/Hysteria через TURN-серверы ВК-звонков.

Ключевые зависимости:
- [vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy) — оригинальный TURN-прокси (Go), адаптирован для gomobile
- [vk-turn-proxy-android](https://github.com/MYSOREZ/vk-turn-proxy-android) — нативный Android-клиент
- [wireguard-go](https://git.zx2c4.com/wireguard-go) — WireGuard реализация на Go
- [pion/turn](https://github.com/pion/turn) — TURN-клиент
- [pion/dtls](https://github.com/pion/dtls) — DTLS шифрование

---

> **Ещё раз:** проект навайбкоден, я не программист. Если видишь баг или знаешь как улучшить — PR welcome. Всё тестировалось руками на iPhone 16 Pro + VPS с 3x-ui.
