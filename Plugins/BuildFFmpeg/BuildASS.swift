//
//  BuildASS.swift
//
//
//  Created by kintan on 12/26/23.
//

import Foundation

class BuildFribidi: BaseBuild {
    init() {
        super.init(library: .libfribidi)
    }

    override func arguments(platform _: PlatformType, arch _: ArchType) -> [String] {
        [
            "-Ddeprecated=false",
            "-Ddocs=false",
            "-Dtests=false",
        ]
    }
}

class BuildHarfbuzz: BaseBuild {
    init() {
        super.init(library: .libharfbuzz)
    }

    override func cFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var cFlags = super.cFlags(platform: platform, arch: arch)
        cFlags.append("-Wno-cast-function-type-strict")
        return cFlags
    }

    override func arguments(platform _: PlatformType, arch _: ArchType) -> [String] {
        [
            "-Dcairo=disabled",
            "-Dglib=disabled",
            "-Dgobject=disabled",
            "-Dintrospection=disabled",
            "-Dtests=disabled",
            "-Ddocs=disabled",
        ]
    }
}

class BuildFreetype: BaseBuild {
    init() {
        super.init(library: .libfreetype)
    }

    override func arguments(platform _: PlatformType, arch _: ArchType) -> [String] {
        [
            "-Dbrotli=disabled",
            "-Dharfbuzz=disabled",
            "-Dpng=disabled",
        ]
    }
}

class BuildPng: BaseBuild {
    init() {
        super.init(library: .libpng)
    }

    override func arguments(platform _: PlatformType, arch _: ArchType) -> [String] {
        ["-DPNG_HARDWARE_OPTIMIZATIONS=yes"]
    }
}

class BuildASS: BaseBuild {
    init() {
        super.init(library: .libass)
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        try autoToolsBuildWithNoSpacePaths(platform: platform, arch: arch, buildURL: buildURL)
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        let safeRoot = URL(fileURLWithPath: "/tmp/ffmpegkit-nospace", isDirectory: true)
        let safeScript = (safeRoot + "Script").path
        let triplet = "\(platform.rawValue)/thin/\(arch.rawValue)"

        let freetypeBase = "\(safeScript)/libfreetype/\(triplet)"
        env["FREETYPE_CFLAGS"] = "-I\(freetypeBase)/include/freetype2"
        env["FREETYPE_LIBS"] = "\(freetypeBase)/lib/libfreetype.a -L\(freetypeBase)/lib -lbz2 -lz"

        let fribidiBase = "\(safeScript)/libfribidi/\(triplet)"
        env["FRIBIDI_CFLAGS"] = "-I\(fribidiBase)/include/fribidi"
        env["FRIBIDI_LIBS"] = "\(fribidiBase)/lib/libfribidi.a"

        let harfbuzzBase = "\(safeScript)/libharfbuzz/\(triplet)"
        env["HARFBUZZ_CFLAGS"] = "-I\(harfbuzzBase)/include/harfbuzz"
        env["HARFBUZZ_LIBS"] = "\(harfbuzzBase)/lib/libharfbuzz.a"

        return env
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        var result =
            [
                "--disable-libtool-lock",
                "--disable-fontconfig",
                "--disable-libunibreak",
                "--disable-require-system-font-provider",
                "--disable-test",
                "--disable-profile",
                "--with-pic",
                "--enable-static",
                "--disable-shared",
                "--disable-fast-install",
                "--disable-dependency-tracking",
                "--host=\(platform.host(arch: arch))",
                "--prefix=\(thinDir(platform: platform, arch: arch).path)",
            ]
        if arch == .x86_64 {
            result.append("--enable-asm")
        }
        return result
    }
}
