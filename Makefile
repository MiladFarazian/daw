.PHONY: generate open build run verify moises-workflows musicai-workflows suno-sidecar yt clean

# List your Moises (developer.moises.ai) workflow slugs (needs MOISES_API_KEY in the environment)
moises-workflows musicai-workflows:
	tools/musicai.sh workflows

# Run a local Suno sidecar for one-click generation (needs SUNO_COOKIE in the environment)
suno-sidecar:
	tools/suno-sidecar.sh

# Download a YouTube URL's audio for Gosan (needs yt-dlp):  make yt URL="https://..."
yt:
	tools/yt-import.sh "$(URL)"

# Regenerate Gosan.xcodeproj from project.yml
generate:
	xcodegen generate

# Headless behavioral checks for the audio export + project format (no GUI/hardware)
verify:
	swiftc Gosan/Models/Models.swift Gosan/Models/ProjectDocument.swift \
		Gosan/Audio/ProjectPackage.swift Gosan/Audio/ClipBuffer.swift Gosan/Audio/ClipProcessing.swift \
		Gosan/Audio/MIDISupport.swift Gosan/Audio/PluginHost.swift Gosan/Audio/AudioExporter.swift tools/AudioChecks.swift \
		-o $(TMPDIR)gosan-audiochecks -framework AVFoundation -framework AudioToolbox
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
