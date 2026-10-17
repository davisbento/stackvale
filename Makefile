MACOS_DIR := macos
PROJECT := $(MACOS_DIR)/Stackvale.xcodeproj
SCHEME := Stackvale
CONFIGURATION ?= Debug
DERIVED_DATA := $(MACOS_DIR)/DerivedData
RELEASE_DERIVED_DATA := $(MACOS_DIR)/DerivedData-Release
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Stackvale.app
RELEASE_APP := $(RELEASE_DERIVED_DATA)/Build/Products/Release/Stackvale.app
DIST_DIR := dist
DMG := $(DIST_DIR)/Stackvale.dmg
SQLITE_DB := $(HOME)/Library/Application Support/Stackvale/stackvale.sqlite3

.PHONY: build release dmg open sqlite web-dev web-build clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) build

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(RELEASE_DERIVED_DATA) build

dmg: release
	mkdir -p $(DIST_DIR) /tmp/stackvale-dmg
	rm -rf /tmp/stackvale-dmg/Stackvale.app
	cp -R $(RELEASE_APP) /tmp/stackvale-dmg/Stackvale.app
	hdiutil create -volname Stackvale -srcfolder /tmp/stackvale-dmg -ov -format UDZO $(DMG)
	cp $(DMG) web/public/Stackvale.dmg
	rm -rf /tmp/stackvale-dmg

open: build
	open $(APP)

web-dev:
	cd web && npm run dev

web-build:
	cd web && npm run build

sqlite:
	sqlite3 "$(SQLITE_DB)"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA) $(RELEASE_DERIVED_DATA) $(DIST_DIR)
