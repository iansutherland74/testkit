//
//  BuildPlacebo.swift
//
//
//  Created by kintan on 12/26/23.
//

import Foundation

class BuildPlacebo: BaseBuild {
    init() {
        super.init(library: .libplacebo)
        let path = directoryURL + "demos/meson.build"
        if let data = FileManager.default.contents(atPath: path.path), var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(of: "if sdl.found()", with: "if false")
            try! str.write(toFile: path.path, atomically: true, encoding: .utf8)
        }
        // Patch atomic support for Apple platforms (where stdatomic is built-in)
        let srcMesonPath = directoryURL + "src/meson.build"
        if let data = FileManager.default.contents(atPath: srcMesonPath.path), var str = String(data: data, encoding: .utf8) {
            let atomicPatch = """
            # Work around missing atomics on some (obscure) platforms
            atomic_test = '''
            #include <stdatomic.h>
            #include <stdint.h>
            int main(void) {
              _Atomic uint32_t x32;
              atomic_init(&x32, 0);
            }'''

            if cc.get_id() == 'clang' and host_machine.system() in ['darwin', 'freebsd']
              # Apple and FreeBSD have built-in atomic support
            elif not cc.links(atomic_test)
              build_deps += cc.find_library('atomic', required: false)
            endif
            """
            str = str.replacingOccurrences(of: """
            # Work around missing atomics on some (obscure) platforms
            atomic_test = '''
            #include <stdatomic.h>
            #include <stdint.h>
            int main(void) {
              _Atomic uint32_t x32;
              atomic_init(&x32, 0);
            }'''

            if not cc.links(atomic_test)
              build_deps += cc.find_library('atomic')
            endif
            """, with: atomicPatch)
            try! str.write(toFile: srcMesonPath.path, atomically: true, encoding: .utf8)
        }
    }

    override func flagsDependencelibrarys() -> [Library] {
      // Meson resolves these via pkg-config. Injecting -I/-L/-l here can break
      // linker search paths when the workspace path contains spaces.
      []
    }

    override func arguments(platform _: PlatformType, arch _: ArchType) -> [String] {
      ["-Dxxhash=disabled", "-Dopengl=disabled", "-Ddemos=false"]
    }
}

class BuildVulkan: BaseBuild {
    init() {
        super.init(library: .vulkan)
    }

    override func platforms() -> [PlatformType] {
        // Placebo编译maccatalyst的时候，vulkan会报找不到UIKit的问题，所以要先屏蔽。
        super.platforms().filter {
        ![.maccatalyst].contains($0)
        }
    }

    override func buildALL() throws {
        var arguments = platforms().map {
            "--\($0.name)"
        }
        let dependencyNames = ["SPIRVTools", "SPIRVCross"]
        let needsDependencyRefresh = dependencyNames.contains { dependencyName in
            platforms().contains { platform in
                let requiredSlice = directoryURL + "External/build/Latest/\(dependencyName).xcframework/\(platform.frameworkName)"
                return !FileManager.default.fileExists(atPath: requiredSlice.path)
            }
        }
        if needsDependencyRefresh || !FileManager.default.fileExists(atPath: (directoryURL + "External/build/Release").path) {
            try Utility.launch(path: (directoryURL + "fetchDependencies").path, arguments: arguments, currentDirectoryURL: directoryURL)
        }
        arguments = platforms().map(\.name)
        if !FileManager.default.fileExists(atPath: (directoryURL + "Package/Release/MoltenVK/static/MoltenVK.xcframework").path) || !BaseBuild.notRecompile {
            try Utility.launch(path: "/usr/bin/make", arguments: arguments, currentDirectoryURL: directoryURL)
        }
        let moltenVKSource = directoryURL + "Package/Release/MoltenVK/static/MoltenVK.xcframework"
        let moltenVKTarget = URL.currentDirectory() + "../Sources/MoltenVK.xcframework"
        if FileManager.default.fileExists(atPath: moltenVKTarget.path) {
          try FileManager.default.removeItem(at: moltenVKTarget)
        }
        try FileManager.default.copyItem(at: moltenVKSource, to: moltenVKTarget)
        let workspaceRoot = directoryURL.deletingLastPathComponent().deletingLastPathComponent()
        var moltenVKPrefixPath = (directoryURL + "Package/Release/MoltenVK").path
        if workspaceRoot.path.contains(" ") {
          let safeWorkspaceRoot = URL(fileURLWithPath: "/tmp/FFmpegKit", isDirectory: true)
          let fm = FileManager.default
          if fm.fileExists(atPath: safeWorkspaceRoot.path) {
            if let target = try? fm.destinationOfSymbolicLink(atPath: safeWorkspaceRoot.path), target != workspaceRoot.path {
              try? fm.removeItem(at: safeWorkspaceRoot)
            }
          }
          if !fm.fileExists(atPath: safeWorkspaceRoot.path) {
            try? fm.createSymbolicLink(atPath: safeWorkspaceRoot.path, withDestinationPath: workspaceRoot.path)
          }
          if fm.fileExists(atPath: safeWorkspaceRoot.path) {
            moltenVKPrefixPath = safeWorkspaceRoot
              .appendingPathComponent(".Script")
              .appendingPathComponent(directoryURL.lastPathComponent)
              .appendingPathComponent("Package/Release/MoltenVK")
              .path
          }
        }
        if moltenVKPrefixPath.contains(" ") {
          throw NSError(domain: "BuildVulkan", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "MoltenVK prefix path contains spaces and cannot be used safely by pkg-config: \(moltenVKPrefixPath)"
          ])
        }
        for platform in platforms() {
            var frameworks = ["CoreFoundation", "CoreGraphics", "Foundation", "IOSurface", "Metal", "QuartzCore"]
            if platform == .macos {
                frameworks.append("Cocoa")
            } else {
                frameworks.append("UIKit")
            }
            if !(platform == .tvos || platform == .tvsimulator) {
                frameworks.append("IOKit")
            }
            let libframework = frameworks.map {
                "-framework \($0)"
            }.joined(separator: " ")
            for arch in platform.architectures {
                let prefix = thinDir(platform: platform, arch: arch) + "lib/pkgconfig"
              if FileManager.default.fileExists(atPath: prefix.path) {
                try FileManager.default.removeItem(at: prefix)
              }
              try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true, attributes: nil)
                let vulkanPC = prefix + "vulkan.pc"

                let content = """
                prefix=\(moltenVKPrefixPath)
                includedir=${prefix}/include
                libdir=${prefix}/static/MoltenVK.xcframework/\(platform.frameworkName)

                Name: Vulkan-Loader
                Description: Vulkan Loader
                Version: 1.2
                Libs: -L${libdir} -lMoltenVK \(libframework)
                Cflags: -I${includedir}
                """
                if !FileManager.default.createFile(atPath: vulkanPC.path, contents: content.data(using: .utf8), attributes: nil) {
                  throw NSError(domain: "BuildVulkan", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create pkg-config file: \(vulkanPC.path)"
                  ])
                }
            }
        }
    }
}

class BuildGlslang: BaseBuild {
    init() {
        super.init(library: .libglslang)
        _ = try? Utility.launch(executableURL: directoryURL + "./update_glslang_sources.py", arguments: [], currentDirectoryURL: directoryURL)
        var path = directoryURL + "External/spirv-tools/tools/reduce/reduce.cpp"
        if let data = FileManager.default.contents(atPath: path.path), var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(of: """
              int res = std::system(nullptr);
              return res != 0;
            """, with: """
              FILE* fp = popen(nullptr, "r");
              return fp == NULL;
            """)
            str = str.replacingOccurrences(of: """
              int status = std::system(command.c_str());
            """, with: """
              FILE* fp = popen(command.c_str(), "r");
            """)
            str = str.replacingOccurrences(of: """
              return status == 0;
            """, with: """
              return fp != NULL;
            """)
            try! str.write(toFile: path.path, atomically: true, encoding: .utf8)
        }
        path = directoryURL + "External/spirv-tools/tools/fuzz/fuzz.cpp"
        if let data = FileManager.default.contents(atPath: path.path), var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(of: """
              int res = std::system(nullptr);
              return res != 0;
            """, with: """
              FILE* fp = popen(nullptr, "r");
              return fp == NULL;
            """)
            str = str.replacingOccurrences(of: """
              int status = std::system(command.c_str());
            """, with: """
              FILE* fp = popen(command.c_str(), "r");
            """)
            str = str.replacingOccurrences(of: """
              return status == 0;
            """, with: """
              return fp != NULL;
            """)
            try! str.write(toFile: path.path, atomically: true, encoding: .utf8)
        }
    }
}

class BuildShaderc: BaseBuild {
    init() {
        super.init(library: .libshaderc)
        _ = try? Utility.launch(executableURL: directoryURL + "utils/git-sync-deps", arguments: [], currentDirectoryURL: directoryURL)
        var path = directoryURL + "third_party/spirv-tools/tools/reduce/reduce.cpp"
        if let data = FileManager.default.contents(atPath: path.path), var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(of: """
              int res = std::system(nullptr);
              return res != 0;
            """, with: """
              FILE* fp = popen(nullptr, "r");
              return fp == NULL;
            """)
            str = str.replacingOccurrences(of: """
              int status = std::system(command.c_str());
            """, with: """
              FILE* fp = popen(command.c_str(), "r");
            """)
            str = str.replacingOccurrences(of: """
              return status == 0;
            """, with: """
              return fp != NULL;
            """)
            try! str.write(toFile: path.path, atomically: true, encoding: .utf8)
        }
        path = directoryURL + "third_party/spirv-tools/tools/fuzz/fuzz.cpp"
        if let data = FileManager.default.contents(atPath: path.path), var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(of: """
              int res = std::system(nullptr);
              return res != 0;
            """, with: """
              FILE* fp = popen(nullptr, "r");
              return fp == NULL;
            """)
            str = str.replacingOccurrences(of: """
              int status = std::system(command.c_str());
            """, with: """
              FILE* fp = popen(command.c_str(), "r");
            """)
            str = str.replacingOccurrences(of: """
              return status == 0;
            """, with: """
              return fp != NULL;
            """)
            try! str.write(toFile: path.path, atomically: true, encoding: .utf8)
        }
    }

    override func frameworks() throws -> [String] {
        ["libshaderc_combined"]
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        try super.build(platform: platform, arch: arch, buildURL: buildURL)
        let thinDir = thinDir(platform: platform, arch: arch)
        let pkgconfig = thinDir + "lib/pkgconfig"
        try FileManager.default.moveItem(at: pkgconfig + "shaderc.pc", to: pkgconfig + "shaderc_shared.pc")
        try FileManager.default.moveItem(at: pkgconfig + "shaderc_combined.pc", to: pkgconfig + "shaderc.pc")
    }
}

class BuildLittleCms: BaseBuild {
    init() {
        super.init(library: .lcms2)
    }
}

class BuildDav1d: BaseBuild {
    init() {
        super.init(library: .libdav1d)
        if Utility.shell("which nasm") == nil {
            Utility.shell("brew install nasm")
        }
    }

    override func arguments(platform _: PlatformType, arch _: ArchType) -> [String] {
        ["-Denable_asm=true", "-Denable_tools=false", "-Denable_examples=false", "-Denable_tests=false"]
    }
}

class BuildDovi: BaseBuild {
    init() {
        super.init(library: .libdovi)
    }

  // pkg-config consumers (meson/cmake) may split unquoted include paths when
  // the workspace path contains spaces. Rewrite dovi.pc to reference a
  // stable no-space symlink under /tmp.
  private func normalizePkgConfigPath(prefix: URL) {
    let spacedScriptDir = URL.currentDirectory.path
    guard spacedScriptDir.contains(" ") else { return }

    let fm = FileManager.default
    let safeRoot = URL(fileURLWithPath: "/tmp/ffmpegkit-nospace", isDirectory: true)
    let safeScriptDir = safeRoot.appendingPathComponent("Script", isDirectory: true)

    do {
      try fm.createDirectory(at: safeRoot, withIntermediateDirectories: true)
      if fm.fileExists(atPath: safeScriptDir.path) {
        if let target = try? fm.destinationOfSymbolicLink(atPath: safeScriptDir.path), target != spacedScriptDir {
          try? fm.removeItem(at: safeScriptDir)
        }
      }
      if !fm.fileExists(atPath: safeScriptDir.path) {
        try fm.createSymbolicLink(atPath: safeScriptDir.path, withDestinationPath: spacedScriptDir)
      }

      let pcFile = prefix.appendingPathComponent("lib/pkgconfig/dovi.pc")
      guard let data = fm.contents(atPath: pcFile.path), var text = String(data: data, encoding: .utf8) else {
        return
      }
      text = text.replacingOccurrences(of: spacedScriptDir, with: safeScriptDir.path)
      try text.write(to: pcFile, atomically: true, encoding: .utf8)
    } catch {
      print("BuildDovi: warning: failed to normalize dovi.pc path: \(error)")
    }
  }

    // Map FFmpegKit platform+arch to Rust target triple.
    // Returns nil for unsupported combos (x86_64-apple-tvos, tvos arm64e).
    private func rustTarget(platform: PlatformType, arch: ArchType) -> String? {
        switch platform {
        case .macos:
            return arch == .x86_64 ? "x86_64-apple-darwin" : "aarch64-apple-darwin"
        case .ios:
            return "aarch64-apple-ios"
        case .isimulator:
            return arch == .x86_64 ? "x86_64-apple-ios" : "aarch64-apple-ios-sim"
        case .tvos:
            // Rust has no arm64e target; handled separately via stub library
            if arch == .arm64e { return nil }
            return "aarch64-apple-tvos"
        case .tvsimulator:
            // x86_64-apple-tvossim has no prebuilt Rust target; handled via stub
            if arch == .x86_64 { return nil }
            return "aarch64-apple-tvos-sim"
        case .xros:
            return "aarch64-apple-visionos"
        case .xrsimulator:
            return "aarch64-apple-visionos-sim"
        default:
            return nil
        }
    }

    // Build an arm64e stub static library so lipo can create a fat tvos binary.
    // The real arm64 slice carries all symbols; this stub just satisfies the xcframework
    // arm64e slot with a valid (empty) arm64e Mach-O archive.
    private func buildArm64eStub() throws {
        let prefix = thinDir(platform: .tvos, arch: .arm64e)
        let arm64prefix = thinDir(platform: .tvos, arch: .arm64)
        let libDir = prefix + "lib"
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        // Copy headers from the arm64 build
        let srcInclude = arm64prefix + "include"
        let dstInclude = prefix + "include"
        if FileManager.default.fileExists(atPath: srcInclude.path) {
            try? FileManager.default.removeItem(at: dstInclude)
            try FileManager.default.copyItem(at: srcInclude, to: dstInclude)
        }
        // Compile an empty C translation unit as arm64e-apple-tvos
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dovi_arm64e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let stubC = tmpDir.appendingPathComponent("stub.c")
        FileManager.default.createFile(atPath: stubC.path, contents: "// dovi arm64e stub\n".data(using: .utf8))
        let stubO = tmpDir.appendingPathComponent("stub.o").path
        let sdk = PlatformType.tvos.isysroot
        let minVer = PlatformType.tvos.minVersion
        try Utility.launch(path: "/usr/bin/clang", arguments: [
            "-target", "arm64e-apple-tvos\(minVer)",
            "-arch", "arm64e",
            "-isysroot", sdk,
            "-c", stubC.path,
            "-o", stubO,
        ])
        try Utility.launch(path: "/usr/bin/ar", arguments: [
            "cr", (libDir + "libdovi.a").path, stubO,
        ])
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func buildTvSimulatorX86_64Stub() throws {
        let prefix = thinDir(platform: .tvsimulator, arch: .x86_64)
        let arm64prefix = thinDir(platform: .tvsimulator, arch: .arm64)
        let libDir = prefix + "lib"
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let srcInclude = arm64prefix + "include"
        let dstInclude = prefix + "include"
        if FileManager.default.fileExists(atPath: srcInclude.path) {
            try? FileManager.default.removeItem(at: dstInclude)
            try FileManager.default.copyItem(at: srcInclude, to: dstInclude)
        }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dovi_tvsim_x86_64_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let stubC = tmpDir.appendingPathComponent("stub.c")
        FileManager.default.createFile(atPath: stubC.path, contents: "// dovi tvsimulator x86_64 stub\n".data(using: .utf8))
        let stubO = tmpDir.appendingPathComponent("stub.o").path
        let sdk = PlatformType.tvsimulator.isysroot
        let minVer = PlatformType.tvsimulator.minVersion
        try Utility.launch(path: "/usr/bin/clang", arguments: [
            "-target", "x86_64-apple-tvos\(minVer)-simulator",
            "-arch", "x86_64",
            "-isysroot", sdk,
            "-c", stubC.path,
            "-o", stubO,
        ])
        try Utility.launch(path: "/usr/bin/ar", arguments: [
            "cr", (libDir + "libdovi.a").path, stubO,
        ])
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // visionOS targets require nightly; others use stable.
    private func cargoToolchain(platform: PlatformType) -> String {
        switch platform {
        case .xros, .xrsimulator:
            return "+nightly"
        default:
            return "+stable"
        }
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        guard let rustTriple = rustTarget(platform: platform, arch: arch) else {
            if platform == .tvos, arch == .arm64e {
                try buildArm64eStub()
            } else if platform == .tvsimulator, arch == .x86_64 {
                try buildTvSimulatorX86_64Stub()
            } else {
                print("BuildDovi: skipping unsupported Rust target \(platform.rawValue)/\(arch.rawValue)")
            }
            return
        }

        let toolchain = cargoToolchain(platform: platform)
        let prefix = thinDir(platform: platform, arch: arch)
        let cargo = "\(NSHomeDirectory())/.cargo/bin/cargo"
        let manifestPath = (directoryURL + "dolby_vision/Cargo.toml").path

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if toolchain == "+nightly" {
            env["RUSTUP_TOOLCHAIN"] = "nightly"
        }

        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true, attributes: nil)

        let args: [String] = [toolchain, "cinstall",
                              "--release",
                              "--target", rustTriple,
                              "--prefix", prefix.path,
                              "--manifest-path", manifestPath,
                              "--features", "capi",
                              "--library-type", "staticlib"]

        try Utility.launch(path: cargo, arguments: args, currentDirectoryURL: directoryURL, environment: env)
        normalizePkgConfigPath(prefix: prefix)
    }
}
