# ==============================================================================
# VK Turn VPN — Top-level Makefile
# ==============================================================================
#
# Быстрый старт:
#   make setup   — установить все зависимости
#   make build   — собрать Go-библиотеку + Xcode-проект
#   make xcode   — открыть в Xcode
#
# ==============================================================================

.PHONY: setup build golib xcode project clean

# Установить все зависимости (однократно)
setup:
	@echo ">>> Проверяю зависимости..."
	@which go > /dev/null || (echo "Установи Go: brew install go" && exit 1)
	@which xcodegen > /dev/null || (echo "Установи xcodegen: brew install xcodegen" && exit 1)
	@echo ">>> Устанавливаю gomobile..."
	go install golang.org/x/mobile/cmd/gomobile@latest
	go install golang.org/x/mobile/cmd/gobind@latest
	$$(go env GOPATH)/bin/gomobile init
	@echo ">>> Всё установлено!"

# Собрать Go-библиотеку (xcframework)
golib:
	@echo ">>> Собираю Go-библиотеку..."
	cd golib && make ios
	@echo ">>> Go-библиотека готова"

# Сгенерировать Xcode-проект
project:
	cd ios && xcodegen generate

# Собрать всё
build: golib project
	@echo ""
	@echo "========================================="
	@echo "  Сборка завершена!"
	@echo "========================================="
	@echo ""
	@echo "  1. Открой: ios/VKTurnVPN.xcodeproj"
	@echo "  2. В project.yml раскомментируй framework зависимости"
	@echo "  3. Запусти xcodegen generate"
	@echo "  4. В Xcode выбери Team для code signing"
	@echo "  5. Build & Run на iPhone"
	@echo ""

# Открыть в Xcode
xcode: project
	open ios/VKTurnVPN.xcodeproj

clean:
	cd golib && make clean
