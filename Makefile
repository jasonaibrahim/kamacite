XCODEGEN ?= xcodegen
DERIVED  := build
APP      := $(DERIVED)/Build/Products/Release/Kamacite.app

.PHONY: generate build run test bench install dev-link clean spike spike-dump

generate:
	$(XCODEGEN) generate

build: generate
	xcodebuild -project kamacite.xcodeproj -scheme kamacite -configuration Release \
	  -derivedDataPath $(DERIVED) -quiet build

run: build
	$(APP)/Contents/MacOS/Kamacite

test:
	swift test --package-path Packages/VWEngine

bench: build
	bench/bench.sh $(APP)

install: build
	ditto $(APP) /Applications/Kamacite.app
	scripts/install-cli.sh /Applications/Kamacite.app

dev-link: build
	scripts/install-cli.sh $(APP)

clean:
	rm -rf $(DERIVED) kamacite.xcodeproj

# P1 text-on-GPU spike: window = Metal vs NSTextView side-by-side
# (a: animate, l: theme, q: quit); dump = PNGs + parity stats.
spike:
	swift run --package-path Spikes/TextOnGPU -c release TextOnGPU

spike-dump:
	swift run --package-path Spikes/TextOnGPU -c release TextOnGPU --dump Spikes/TextOnGPU/out
