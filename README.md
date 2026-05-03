# FFmpegKit ![GitHub release](https://img.shields.io/badge/release-v1.0.0--visionos-blue.svg)

> **visionOS fork** — This is a fork of [kingslay/FFmpegKit](https://github.com/kingslay/FFmpegKit) rebuilt with full **visionOS (xrOS)** support. All 35 xcframeworks include `xros-arm64` and `xros-arm64-simulator` slices in addition to the standard iOS / macOS / tvOS slices.

`FFmpegKit` is a collection of tools to use `FFmpeg` in `iOS`, `macOS`, `tvOS`, `xrOS`, `visionOS` applications.

It includes scripts to build `FFmpeg` native libraries, three executable products `ffplay`/`ffmpeg`/`ffprobe` on macOS.

### Features
- Scripts to build FFmpeg native libraries
- Three executable products `ffplay`/`ffmpeg`/`ffprobe` on macOS
- Supports native platforms: `iOS`, `macOS`, `tvOS`, `visionOS` (xrOS)
- Build MPV
- **All 35 xcframeworks include `xros-arm64` + `xros-arm64-simulator` slices**

### visionOS Platform Coverage

Every xcframework in `Sources/` ships with the following slices:

| Slice | Platforms |
|---|---|
| `ios-arm64` | iPhone / iPad device |
| `ios-arm64_x86_64-simulator` | iPhone / iPad simulator |
| `macos-arm64_x86_64` | Mac (Apple Silicon + Intel) |
| `tvos-arm64_arm64e` | Apple TV device |
| `tvos-arm64_x86_64-simulator` | Apple TV simulator |
| `xros-arm64` | Apple Vision Pro device |
| `xros-arm64-simulator` | Apple Vision Pro simulator |

Nine libraries (`Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `libfontconfig`, `libmpv`, `Libswresample`, `Libswscale`) additionally include a `maccatalyst` slice.

> **Note on `libsmbclient`:** The `libsmbclient.xcframework` is built from Samba 4.24.1 with a custom patch set to support cross-compilation for visionOS/tvOS targets (Heimdal ASN.1 compiler, PIDL, and cross-answer fixes). SMB client functionality on visionOS is subject to Apple sandbox restrictions.

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/iansutherland74/testkit.git", .branch("ffmpeg-master-visionos2"))
]
```

## Build Scripts
```bash
swift package --disable-sandbox BuildFFmpeg

```

## Run ffmpeg ffprobe in code(Features of the lgpl version)

```swift
var arguments = ["ffmpeg", "-i", "file1.mp4", "-c:v", "mpeg4", "file2.mp4"]
var argv = arguments.map {
    UnsafeMutablePointer(mutating: ($0 as NSString).utf8String)
}
ffmpeg_execute(Int32(arguments.count), &argv)

arguments = ["ffprobe", "-h"]
argv = arguments.map {
    UnsafeMutablePointer(mutating: ($0 as NSString).utf8String)
}
ffprobe_execute(Int32(arguments.count), &argv)
```

## Executable product
```bash
swift run ffplay
swift run ffmpeg
swift run ffprobe
```

## Help 
```bash
swift package BuildFFmpeg -h
```

```bash
        Usage: swift package BuildFFmpeg [OPTION]...
        Default Build: swift package --disable-sandbox BuildFFmpeg enable-libshaderc enable-vulkan enable-lcms2 enable-libdav1d enable-libplacebo enable-gmp enable-nettle enable-gnutls enbale-readline enable-libsmbclient enable-libsrt enable-libzvbi enable-libfreetype enable-libfribidi enable-libharfbuzz enable-libass enable-FFmpeg enable-libmpv

        Options:
            h, -h, --help       display this help and exit
            notRecompile        If there is a library, then there is no need to recompile
            gitCloneAll         git clone not add --depth 1
            enable-debug,       build ffmpeg with debug information
            platforms=xros      deployment platform: macos,ios,isimulator,tvos,tvsimulator,xros,xrsimulator,maccatalyst,watchos,watchsimulator
            --xx                add ffmpeg Configuers

        Libraries:
            enable-libshaderc   build with libshaderc
            enable-vulkan       depend enable-libshaderc
            enable-libdav1d     build with libdav1d
            enable-libplacebo   depend enable-libshaderc enable-vulkan enable-lcms2 enable-libdav1d
            enable-nettle       depend enable-gmp
            enable-gnutls       depend enable-gmp enable-nettle
            enable-libsmbclient depend enable-gmp enable-nettle enable-gnutls enbale-readline
            enable-libsrt       depend enable-openssl or enable-gnutls
            enable-libfreetype  build with libfreetype
            enable-libharfbuzz  depend enable-libfreetype
            enable-libass       depend enable-libfreetype enable-libfribidi enable-libharfbuzz
            enable-libzvbi      build with libzvbi
            enable-FFmpeg       build with FFmpeg
            enable-libmpv       depend enable-libass enable-FFmpeg
            enable-openssl      build with openssl [no]
```
## License
Because FFmpegKit includes libsmbclient by default, and the GPL is turned on when compiling FFmepg and mpv. So FFmpegKit uses the GPL license.
 
Additionally, there is a paid version that adopts the LGPL license (contact us).  
