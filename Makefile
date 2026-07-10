XCODEGEN ?= xcodegen
DERIVED  := build
APP      := $(DERIVED)/Build/Products/Release/vw.app

.PHONY: generate build run test bench install dev-link clean

generate:
	$(XCODEGEN) generate

build: generate
	xcodebuild -project vw.xcodeproj -scheme vw -configuration Release \
	  -derivedDataPath $(DERIVED) -quiet build

run: build
	$(APP)/Contents/MacOS/vw

test:
	swift test --package-path Packages/VWEngine

bench: build
	bench/bench.sh $(APP)

install: build
	ditto $(APP) /Applications/vw.app
	scripts/install-cli.sh /Applications/vw.app

dev-link: build
	scripts/install-cli.sh $(APP)

clean:
	rm -rf $(DERIVED) vw.xcodeproj
