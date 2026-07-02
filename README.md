# ChronoVolume

ChronoVolume is a macOS SwiftUI and Metal application for exploring video as a time volume. It loads video frames into a 3D volume, previews axis and arbitrary-plane slices, renders volumetric views, supports composition/keyframe workflows, and includes export and distributed-rendering experiments.

## Features

- Video-to-volume loading and preview
- T/X/Y axis slicing and arbitrary reference-plane slicing
- SwiftUI interface with Metal-backed rendering
- Composition layers, keyframes, expressions, blend modes, and export controls
- High-precision slice export paths
- Experimental distributed rendering worker/client components

## Requirements

- macOS 14 or newer
- Xcode with Swift 5 support
- Apple Silicon or Intel Mac with Metal support

## Build

1. Open `ChronoVolume.xcodeproj` in Xcode.
2. Select the `ChronoVolume` scheme.
3. Build and run the macOS app target.

## Privacy And Repository Hygiene

This export intentionally excludes local generated media, virtual environments, Xcode user state, build artifacts, and personal utility scripts with absolute local paths. Bundle identifiers in this copy use the neutral `org.chronovolume.*` namespace.

## License

Choose and add a license before publishing publicly. Common choices include MIT, Apache-2.0, GPL-3.0, or a custom license, depending on how you want others to use the project.
