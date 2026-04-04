# ==============================================================================
# Go Library Build — создаёт Swinterlib.xcframework для iOS
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

FRAMEWORK_NAME = Swinterlib
PACKAGE = swinter/golib/vpnlib

.PHONY: ios android clean deps tidy

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
		-tags with_utls \
		-o $(FRAMEWORK_NAME).xcframework \
		./vpnlib
	@echo ">>> Done: $(FRAMEWORK_NAME).xcframework"
	@echo ">>> Скопируй в ios/ и раскомментируй зависимость в project.yml"

# Собрать AAR для Android
android: tidy
	@echo ">>> Building $(FRAMEWORK_NAME).aar for Android..."
	GOTOOLCHAIN=auto GOFLAGS="-ldflags=-checklinkname=0" $(shell go env GOPATH)/bin/gomobile bind \
		-target=android \
		-androidapi 24 \
		-o $(FRAMEWORK_NAME).aar \
		./vpnlib
	@echo ">>> Done: $(FRAMEWORK_NAME).aar"

clean:
	rm -rf $(FRAMEWORK_NAME).xcframework
	rm -rf $(FRAMEWORK_NAME).aar $(FRAMEWORK_NAME)-sources.jar
	rm -rf build/
