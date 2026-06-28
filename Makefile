.PHONY: generate open build run clean

# Regenerate Daw.xcodeproj from project.yml
generate:
	xcodegen generate

# Generate and open in Xcode
open: generate
	open Daw.xcodeproj

# Compile-check from the command line (no code signing)
build: generate
	xcodebuild -project Daw.xcodeproj -scheme Daw -configuration Debug \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf Daw.xcodeproj DerivedData build
