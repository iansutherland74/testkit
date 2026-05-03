//
//  SSL.swift
//
//
//  Created by kintan on 12/26/23.
//

import Foundation

class BuildOpenSSL: BaseBuild {
    init() {
        super.init(library: .openssl)
    }

    override func frameworks() throws -> [String] {
        ["libssl", "libcrypto"]
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        var array = [
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
            "no-async", "no-shared", "no-dso", "no-engine", "no-tests",
            arch == .x86_64 ? "darwin64-x86_64" : arch == .arm64e ? "iphoneos-cross" : "darwin64-arm64",
        ]
        if [PlatformType.tvos, .tvsimulator, .watchos, .watchsimulator].contains(platform) {
            array.append("-DHAVE_FORK=0")
        }
        return array
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        try? _ = Utility.launch(path: "/usr/bin/make", arguments: ["clean"], currentDirectoryURL: buildURL)
        try? _ = Utility.launch(path: "/usr/bin/make", arguments: ["distclean"], currentDirectoryURL: buildURL)
        let environ = environment(platform: platform, arch: arch)
        try configure(buildURL: buildURL, environ: environ, platform: platform, arch: arch)
        // OpenSSL 3.6+ embeds absolute source paths as Makefile prerequisites for configdata.pm.
        // When the project path contains spaces, make misparses the prerequisite list and fails.
        // Replace absolute source-dir references with relative paths, which have no spaces.
        let makefileURL = buildURL.appendingPathComponent("Makefile")
        if var content = try? String(contentsOf: makefileURL, encoding: .utf8) {
            let absPrefix = directoryURL.path + "/"
            // Relative path from buildURL (.Script/openssl/<platform>/scratch/<arch>) up to source dir
            let relPrefix = "../../../../\(library.rawValue)-\(library.version)/"
            content = content.replacingOccurrences(of: absPrefix, with: relPrefix)
            try? content.write(to: makefileURL, atomically: true, encoding: .utf8)
        }
        try Utility.launch(path: "/usr/bin/make", arguments: ["-j8"], currentDirectoryURL: buildURL, environment: environ)
        try Utility.launch(path: "/usr/bin/make", arguments: ["-j8", "install"], currentDirectoryURL: buildURL, environment: environ)
    }
}

class BuildBoringSSL: BaseBuild {
    init() {
        super.init(library: .boringssl)
        if Utility.shell("which go") == nil {
            Utility.shell("brew install go")
        }
    }
}

class BuildLibreSSL: BaseBuild {
    init() {
        // The LibreSSL git repo lacks generated files (VERSION, tls/tls.sym) that CMake
        // requires. Download the official release tarball from OpenBSD instead.
        let srcDir = URL.currentDirectory + "libtls-\(Library.libtls.version)"
        if !FileManager.default.fileExists(atPath: srcDir.path) {
            let ver = Library.libtls.version.hasPrefix("v")
                ? String(Library.libtls.version.dropFirst())
                : Library.libtls.version
            let tarballURL = "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-\(ver).tar.gz"
            let tarballPath = (URL.currentDirectory + "libressl-\(ver).tar.gz").path
            try! Utility.launch(path: "/usr/bin/curl", arguments: ["-L", "-o", tarballPath, tarballURL])
            try! FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true, attributes: nil)
            try! Utility.launch(path: "/usr/bin/tar", arguments: ["xf", tarballPath, "-C", srcDir.path, "--strip-components", "1"])
            try? FileManager.default.removeItem(atPath: tarballPath)
        }
        super.init(library: .libtls)
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        var args = super.arguments(platform: platform, arch: arch)
        // Disable tests and apps — LibreSSL only adds the tests subdirectory when
        // both LIBRESSL_APPS and LIBRESSL_TESTS are ON; the test COMPILE_FLAGS embed
        // the space-containing source path which breaks clang. BUILD_TESTING is a
        // CMake/CTest variable but LibreSSL uses its own LIBRESSL_TESTS option.
        args.append("-DLIBRESSL_TESTS=OFF")
        args.append("-DLIBRESSL_APPS=OFF")
        return args
    }

    override func cFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var cFlags = super.cFlags(platform: platform, arch: arch)
        if [PlatformType.tvos, .tvsimulator, .watchos, .watchsimulator].contains(platform) {
            cFlags.append("-DOPENSSL_NO_SPEED=1")
        }
        return cFlags
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        if [PlatformType.tvos, .tvsimulator, .watchos, .watchsimulator].contains(platform) {
            env["CFLAGS"]? += " -DOPENSSL_NO_SPEED=1"
        }
        return env
    }
}
