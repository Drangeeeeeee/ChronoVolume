# ChronoVolume

ChronoVolume is a macOS SwiftUI and Metal application for exploring video as a time volume. It loads video frames into a 3D volume, previews axis and arbitrary-plane slices, renders volumetric views, supports composition/keyframe workflows, and includes export and distributed-rendering experiments.

## Features

- Video-to-volume loading and preview
- T/X/Y axis slicing and arbitrary reference-plane slicing
- SwiftUI interface with Metal-backed rendering
- Composition layers, keyframes, expressions, blend modes, and export controls
- High-precision slice export paths
- Experimental distributed rendering worker/client components

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
