XCODEGEN ?= xcodegen
DERIVED  := build
APP      := $(DERIVED)/Build/Products/Release/Kamacite.app

# --- Release signing/notarization ------------------------------------------
# Dev builds stay ad-hoc signed (project.yml); `make release` re-signs the
# built app with Developer ID + hardened runtime, packages a DMG, notarizes
# it with notarytool, and staples the ticket. One-time setup:
#   1. Developer ID Application cert in the login keychain
#      (Apple Developer portal → Certificates, requires the paid program)
#   2. xcrun notarytool store-credentials $(NOTARY_PROFILE) \
#        --apple-id you@example.com --team-id TEAMID --password <app-specific>
SIGN_ID        ?= Developer ID Application
NOTARY_PROFILE ?= kamacite-notary
VERSION        := $(shell sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
DIST           := dist
DMG            := $(DIST)/Kamacite-$(VERSION).dmg

.PHONY: generate build run test bench bench-gate check install dev-link clean \
        spike spike-dump release sign dmg notarize smoke edit-bench

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

# Perf regression gate: holds cold first-pixel p50 and scroll-frame p95 to the
# ceilings in bench/baseline.json. Raising a ceiling requires a documented
# `revisions` entry in the same change — gate.py rejects raises without one.
bench-gate: build
	python3 bench/gate.py $(APP)

# End-to-end smoke of the edit server: real app, isolated socket, every verb
# through the kama CLI, byte truth asserted on disk.
smoke: build
	scripts/edit-smoke.sh

# Edit-latency measurement (informational; a baseline ceiling lands once
# quiet-machine numbers exist): seeded synthetic edits through the real
# apply→encode path. VW_EDIT_STORM=1 with the scroll bench checks edits
# don't break 120Hz.
edit-bench: build
	VW_EDIT_BENCH=1 $(APP)/Contents/MacOS/Kamacite --bench bench/corpus/typical-llm.md
	VW_EDIT_BENCH=1 $(APP)/Contents/MacOS/Kamacite --bench bench/corpus/large.md

# The full pre-PR suite: engine unit tests + the perf gate + the edit-server
# smoke. A change that fails `make check` either fixes its regression or
# justifies a new ceiling.
check: test bench-gate smoke

install: build
	ditto $(APP) /Applications/Kamacite.app
	scripts/install-cli.sh /Applications/Kamacite.app

dev-link: build
	scripts/install-cli.sh $(APP)

clean:
	rm -rf $(DERIVED) kamacite.xcodeproj $(DIST)

# --- Release pipeline: build → sign → dmg → notarize -----------------------

release: notarize
	@echo "Release artifact ready: $(DMG)"
	@shasum -a 256 $(DMG)

# Re-sign inner-to-outer (embedded kama helper first, then the bundle seal)
# with hardened runtime + secure timestamp — both required by notarization.
sign: build
	@security find-identity -v -p codesigning | grep -q "$(SIGN_ID)" || \
	  { echo "error: no '$(SIGN_ID)' certificate in the keychain."; \
	    echo "Create one at developer.apple.com → Certificates (paid program required),"; \
	    echo "or override: make release SIGN_ID='Developer ID Application: Name (TEAMID)'"; \
	    exit 1; }
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" \
	  $(APP)/Contents/Helpers/kama
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP)
	codesign --verify --deep --strict $(APP)

dmg: sign
	rm -rf $(DIST)/dmg-stage $(DMG)
	mkdir -p $(DIST)/dmg-stage
	ditto $(APP) $(DIST)/dmg-stage/Kamacite.app
	ln -s /Applications $(DIST)/dmg-stage/Applications
	hdiutil create -volname Kamacite -srcfolder $(DIST)/dmg-stage \
	  -fs HFS+ -format UDZO -imagekey zlib-level=9 $(DMG)
	rm -rf $(DIST)/dmg-stage
	codesign --force --timestamp --sign "$(SIGN_ID)" $(DMG)

notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	@echo "Gatekeeper check:"
	spctl --assess --type open --context context:primary-signature -v $(DMG)

# P1 text-on-GPU spike: window = Metal vs NSTextView side-by-side
# (a: animate, l: theme, q: quit); dump = PNGs + parity stats.
spike:
	swift run --package-path Spikes/TextOnGPU -c release TextOnGPU

spike-dump:
	swift run --package-path Spikes/TextOnGPU -c release TextOnGPU --dump Spikes/TextOnGPU/out
