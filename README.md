# ChronoVolume

ChronoVolume is a macOS SwiftUI and Metal application for exploring video as a time volume. It loads video frames into a 3D volume, previews axis and arbitrary-plane slices, renders volumetric views, supports composition/keyframe workflows, and includes export and distributed-rendering experiments.

## Features

- Video-to-volume loading and preview
- T/X/Y axis slicing and arbitrary reference-plane slicing
- SwiftUI interface with Metal-backed rendering
- Composition layers, keyframes, expressions, blend modes, and export controls
- High-precision slice export paths
- Experimental distributed rendering worker/client components
- Paired `A_color` + `B_alpha` input with strict presentation-timestamp alignment
- External Alpha from gray8/10/12/16le or a selected RGB(A) channel, including FFV1/MKV through FFmpeg
- Straight-Alpha RGBA8 interaction previews that retain hidden RGB, plus a separate UInt16 Alpha cache sidecar

## Paired color and alpha videos

Use **导入AlphaCheater** to select one or more files. The supported `name_A_color.*` / `name_B_alpha.*`, `name-A_color.*` / `name-B_alpha.*`, and `A_color.*` / `B_alpha.*` conventions are grouped by normalized directory and filename prefix. Importing a missing matching role later upgrades the existing media item in place; same-role conflicts are reported and never silently replace the retained file. External Alpha is merged while building the time volume; it is not a Track Matte. The default synchronization and resize policies are strict. Nearest-frame, timeline resampling, trim, and scale behavior must be enabled explicitly for real `A_color + B_alpha` pairs.

The interactive volume remains RGBA8, so external Alpha is rounded to 8-bit for interactive rendering. A `B_alpha`-only import creates a straight-Alpha white model and is supported for interactive RGBA8 preview and ordinary local RGBA8 export. **Only B_alpha at 8-bit or below is supported by the current B-only distributed RGBA8 renderer.** gray10/12/16le remains accepted for interactive white-model preview, but distributed paired export rejects it before transfer. The high-precision cache writes a source-display-resolution, source-timeline UInt16 Alpha sidecar with dimensions, PTS, range, settings, endianness, and source/sidecar hashes for real pairs. The current paired renderer can preserve both inputs only when A_color and B_alpha are at most 8-bit; a paired high-precision or distributed job containing higher-bit-depth color or Alpha is explicitly rejected rather than silently exporting A_color alone or labeling RGBA8 data as high precision. B-only high-precision caching and paired rendering above 8-bit are not currently supported.

Paired cache keys use sorted-key settings serialization and immutable per-operation cache contexts. Cache reads re-hash both source files, so changing content without changing its path, size, or modification date still invalidates the cache. Source-resolution distributed export constructs one host paired volume before scheduling, sends its dimensions, depth, PTS, association, and output bit depth in the Worker manifest, and rejects any Worker reconstruction that differs. Before source-resolution decoding, ChronoVolume reports a conservative peak-memory estimate and rejects over-budget media until the paired decoder is fully streaming; UInt16 sidecars are written in bounded chunks.

External input association is selectable. Straight input keeps A_color RGB unchanged. Premultiplied input is unpremultiplied only after the aligned B_alpha value is known; pixels whose B_alpha is zero retain their encoded RGB but are reported as unrecoverable because premultiplication has already discarded the original hidden color.

## Windows Python Prototype

This repository also includes a Windows-friendly Python prototype in `Python原型-Windows可用/`.

That folder contains:

- `ChronoVolume-原型程序.py`: the Python prototype application
- `Start-ChronoVolume-Prototype-Setup.cmd`: double-click launcher for Windows users
- `ChronoVolumePrototypeSetupAssistant.ps1`: Chinese GUI setup assistant
- `requirements-chronovolume-prototype.txt`: Python package requirements
- `README_WINDOWS_SETUP.md`: Windows setup instructions in Chinese

The prototype can install/check Python, FFmpeg, and the required Python packages on Windows, then launch the prototype app.

## Requirements

For the main macOS app:

- macOS 14 or newer
- Xcode with Swift 5 support
- Apple Silicon or Intel Mac with Metal support
- FFmpeg and ffprobe for MKV, FFV1, or high-bit-depth external Alpha fallback decoding (`brew install ffmpeg`)

For the Windows Python prototype:

- Windows 10/11
- PowerShell
- Internet access for first-time dependency installation

## Build

1. Open `ChronoVolume.xcodeproj` in Xcode.
2. Select the `ChronoVolume` scheme.
3. Build and run the macOS app target.

## Privacy And Repository Hygiene

This export intentionally excludes local generated media, virtual environments, Xcode user state, build artifacts, and personal utility scripts with absolute local paths. Bundle identifiers in this copy use the neutral `org.chronovolume.*` namespace.

## License

This project is released under the MIT License. See `LICENSE` for details.
