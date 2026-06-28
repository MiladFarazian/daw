.PHONY: generate open build run clean

# Regenerate Gosan.xcodeproj from project.yml
generate:
	xcodegen generate

# Generate and open in Xcode
open: generate
	open Gosan.xcodeproj

# Compile-check from the command line (no code signing)
build: generate
	xcodebuild -project Gosan.xcodeproj -scheme Gosan -configuration Debug \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf Gosan.xcodeproj DerivedData build
