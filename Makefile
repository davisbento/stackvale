PROJECT := Stackvale.xcodeproj
SCHEME := Stackvale
CONFIGURATION := Debug
DERIVED_DATA := DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Stackvale.app
SQLITE_DB := $(HOME)/Library/Application Support/Stackvale/stackvale.sqlite3

.PHONY: build open sqlite clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) build

open: build
	open $(APP)

sqlite:
	sqlite3 "$(SQLITE_DB)"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)
