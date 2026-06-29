.PHONY: generate open build run verify musicai-workflows clean

# List your Music.ai workflow slugs (needs MUSICAI_API_KEY in the environment)
musicai-workflows:
	tools/musicai.sh workflows

# Regenerate Gosan.xcodeproj from project.yml
generate:
	xcodegen generate

# Headless behavioral checks for the audio export + project format (no GUI/hardware)
verify:
	swiftc Gosan/Models/Models.swift Gosan/Models/ProjectDocument.swift \
		Gosan/Audio/AudioExporter.swift tools/AudioChecks.swift \
		-o $(TMPDIR)gosan-audiochecks -framework AVFoundation
	$(TMPDIR)gosan-audiochecks

# Generate and open in Xcode
open: generate
	open Gosan.xcodeproj

# Compile-check from the command line (no code signing)
build: generate
	xcodebuild -project Gosan.xcodeproj -scheme Gosan -configuration Debug \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf Gosan.xcodeproj DerivedData build
