PROJECT := Stackvale.xcodeproj
SCHEME := Stackvale
CONFIGURATION := Debug
DERIVED_DATA := DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Stackvale.app

.PHONY: build open clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) build

open: build
	open $(APP)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)
