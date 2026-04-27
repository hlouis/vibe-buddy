# Vibe Buddy — top-level developer commands.
# `make` (no args) prints the menu.
#
# External tools each target needs (install via Homebrew):
#   xcodegen     — brew install xcodegen     (generate xcodeproj from project.yml)
#   xcbeautify   — brew install xcbeautify   (pretty-print xcodebuild output)
#   platformio   — brew install platformio   (firmware build / flash / monitor)
#
# Targets fail loudly if a tool is missing — install it and re-run.

.DEFAULT_GOAL := help

# --- project generation ----------------------------------------------------

.PHONY: gen gen-macos gen-ios

gen: gen-macos gen-ios   ## regenerate both Xcode projects (needs: xcodegen)

gen-macos:               ## regenerate macos-app/VibeBuddy-macOS.xcodeproj (needs: xcodegen)
	cd macos-app && xcodegen generate

gen-ios:                 ## regenerate ios-app/VibeBuddy-iOS.xcodeproj (needs: xcodegen)
	cd ios-app && xcodegen generate

# --- build -----------------------------------------------------------------

.PHONY: build build-macos build-ios

build: build-macos build-ios  ## build both apps in Debug (needs: xcodegen, xcbeautify)

build-macos: gen-macos        ## build the macOS app (needs: xcodegen, xcbeautify)
	cd macos-app && xcodebuild -project VibeBuddy-macOS.xcodeproj \
		-scheme VibeBuddy-macOS -configuration Debug build | xcbeautify

build-ios: gen-ios            ## build the iOS app for Simulator (needs: xcodegen, xcbeautify)
	cd ios-app && xcodebuild -project VibeBuddy-iOS.xcodeproj \
		-scheme VibeBuddy-iOS -configuration Debug \
		-destination 'generic/platform=iOS Simulator' build | xcbeautify

# --- tests -----------------------------------------------------------------

.PHONY: test test-shared test-ios

test: test-shared test-ios    ## run all unit tests (needs: xcodegen, xcbeautify)

test-shared:                  ## SwiftPM tests for VibeBuddyCore (no extra deps)
	cd shared && swift test

test-ios: gen-ios             ## iOS app unit tests on Simulator (needs: xcodegen, xcbeautify)
	cd ios-app && xcodebuild -project VibeBuddy-iOS.xcodeproj \
		-scheme VibeBuddy-iOS -destination 'platform=iOS Simulator,name=iPhone 16' test | xcbeautify

# --- open in Xcode ---------------------------------------------------------

.PHONY: open

open:                         ## open the umbrella workspace in Xcode
	open VibeBuddy.xcworkspace

# --- firmware --------------------------------------------------------------

.PHONY: fw fw-upload fw-monitor

fw:                           ## build firmware (needs: platformio)
	cd firmware && pio run

fw-upload:                    ## flash firmware to attached M5Stack (needs: platformio)
	cd firmware && pio run -t upload

fw-monitor:                   ## tail the firmware serial log (needs: platformio)
	cd firmware && pio device monitor

# --- cleanup ---------------------------------------------------------------

.PHONY: clean clean-derived clean-shared

clean: clean-derived clean-shared  ## remove all build outputs

clean-derived:                ## wipe Xcode DerivedData for both apps
	rm -rf macos-app/build macos-app/DerivedData
	rm -rf ios-app/build ios-app/DerivedData
	rm -rf ~/Library/Developer/Xcode/DerivedData/VibeBuddy-*

clean-shared:                 ## wipe shared SwiftPM build cache
	rm -rf shared/.build shared/build

# --- help ------------------------------------------------------------------

.PHONY: help

help:                         ## show this menu
	@awk 'BEGIN {FS = ":.*## "; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
		/^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
