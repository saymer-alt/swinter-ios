# ==============================================================================
# Go Library Build — создаёт Vpnlib.xcframework для iOS
# ==============================================================================
#
# Зависимости:
#   brew install go
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   gomobile init
#
# Сборка:
#   make ios     — собрать xcframework для iOS (iPhone)
#   make clean   — удалить артефакты
# ==============================================================================

FRAMEWORK_NAME = Vpnlib
PACKAGE = vkturnvpn/golib/vpnlib

.PHONY: ios clean deps tidy

# Установить зависимости Go
deps:
	go install golang.org/x/mobile/cmd/gomobile@latest
	go install golang.org/x/mobile/cmd/gobind@latest
	$(shell go env GOPATH)/bin/gomobile init

# go mod tidy
tidy:
	GOTOOLCHAIN=auto go mod tidy

# Собрать xcframework для iOS
ios: tidy
	@echo ">>> Building $(FRAMEWORK_NAME).xcframework for iOS..."
	GOTOOLCHAIN=auto $(shell go env GOPATH)/bin/gomobile bind \
		-target=ios \
		-o $(FRAMEWORK_NAME).xcframework \
		./vpnlib
	@echo ">>> Done: $(FRAMEWORK_NAME).xcframework"
	@echo ">>> Скопируй в ios/ и раскомментируй зависимость в project.yml"

clean:
	rm -rf $(FRAMEWORK_NAME).xcframework
	rm -rf build/
