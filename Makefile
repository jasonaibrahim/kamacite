XCODEGEN ?= xcodegen
DERIVED  := build
APP      := $(DERIVED)/Build/Products/Release/vw.app

.PHONY: generate build run test bench install dev-link clean spike spike-dump

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

# P1 text-on-GPU spike: window = Metal vs NSTextView side-by-side
# (a: animate, l: theme, q: quit); dump = PNGs + parity stats.
spike:
	swift run --package-path Spikes/TextOnGPU -c release TextOnGPU

spike-dump:
	swift run --package-path Spikes/TextOnGPU -c release TextOnGPU --dump Spikes/TextOnGPU/out
