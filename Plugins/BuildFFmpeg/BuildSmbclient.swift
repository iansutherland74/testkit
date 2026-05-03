//
//  BuildSmbclient.swift
//
//
//  Created by kintan on 12/26/23.
//

import Foundation

// MARK: - No-space autotools helper

/// Autotools configure/make/install routinely fail when the workspace path
/// contains spaces (e.g. `config.sub` run via `/bin/sh unquoted/path`, or
/// `ginstall` word-splitting a `--prefix` that contains spaces).
///
/// This helper works around both problems by:
///   1. Symlinking the source tree under `/tmp/ffmpegkit-nospace/` so that
///      every script the build system invokes sees a space-free path.
///   2. Installing to a temporary no-space prefix, then copying the result to
///      the real `thinDir` afterwards.
///
/// An optional `postConfigure` closure runs after `configure` succeeds and
/// before `make`, which lets callers patch generated Makefiles (e.g. GnuTLS).
extension BaseBuild {
    func autoToolsBuildWithNoSpacePaths(
        platform: PlatformType,
        arch: ArchType,
        buildURL: URL,
        postConfigure: (() throws -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let safeRoot = URL(fileURLWithPath: "/tmp/ffmpegkit-nospace", isDirectory: true)
        try? fm.createDirectory(at: safeRoot, withIntermediateDirectories: true, attributes: nil)

        // Build the base environment (which may contain paths with spaces in CFLAGS/LDFLAGS/PKG_CONFIG_LIBDIR).
        var environ = environment(platform: platform, arch: arch)

        // Create a no-space symlink for the .Script directory so that all dependency
        // -I/-L/pkg-config paths embedded in env vars become space-free.
        let spacedScriptDir = URL.currentDirectory.path  // e.g. /Users/sutherland/Xcode Projects/FFmpegKit/.Script
        let safeScriptLink = (safeRoot + "Script").path
        if fm.fileExists(atPath: safeScriptLink) {
            if let target = try? fm.destinationOfSymbolicLink(atPath: safeScriptLink),
               target != spacedScriptDir {
                try? fm.removeItem(atPath: safeScriptLink)
            }
        }
        if !fm.fileExists(atPath: safeScriptLink) {
            try fm.createSymbolicLink(atPath: safeScriptLink, withDestinationPath: spacedScriptDir)
        }

        // Replace every occurrence of the spaced .Script path with the no-space symlink
        // in all environment variable values.
        for (key, value) in environ {
            environ[key] = value.replacingOccurrences(of: spacedScriptDir, with: safeScriptLink)
        }

        // Symlink source so config.sub and autogen.sh see a space-free path.
        // Must be done BEFORE autogen so that any unquoted $srcdir in autogen.sh works.
        let safeSource = safeRoot + "\(library.rawValue)-\(library.version)"
        if fm.fileExists(atPath: safeSource.path) {
            if let target = try? fm.destinationOfSymbolicLink(atPath: safeSource.path),
               target != directoryURL.path {
                try? fm.removeItem(at: safeSource)
            }
        }
        if !fm.fileExists(atPath: safeSource.path) {
            try fm.createSymbolicLink(atPath: safeSource.path, withDestinationPath: directoryURL.path)
        }

        // If the configure script does not yet exist, generate it from bootstrap/autogen,
        // running via the no-space symlinked path so unquoted shell variables don't break.
        let configureURL = safeSource + "configure"
        if !fm.fileExists(atPath: configureURL.path) {
            var bootstrap = safeSource + "bootstrap"
            if !fm.fileExists(atPath: bootstrap.path) {
                bootstrap = safeSource + ".bootstrap"
            }
            if fm.fileExists(atPath: bootstrap.path) {
                try Utility.launch(executableURL: bootstrap, arguments: [], currentDirectoryURL: safeSource, environment: environ)
            } else {
                let autogen = safeSource + "autogen.sh"
                if fm.fileExists(atPath: autogen.path) {
                    var env = environ
                    env["NOCONFIGURE"] = "1"
                    try Utility.launch(executableURL: autogen, arguments: [], currentDirectoryURL: safeSource, environment: env)
                }
            }
        }

        // Use a no-space prefix so ginstall doesn't word-split.
        let safePrefix = safeRoot + "install-\(library.rawValue)-\(platform.rawValue)-\(arch.rawValue)"
        try? fm.removeItem(at: safePrefix)
        try fm.createDirectory(at: safePrefix, withIntermediateDirectories: true, attributes: nil)

        // Use a no-space build/scratch directory so that the generated libtool script
        // does not embed the spaced workspace path (libtool hardcodes CWD at configure time).
        let safeBuildDir = safeRoot + "build-\(library.rawValue)-\(platform.rawValue)-\(arch.rawValue)"
        try? fm.removeItem(at: safeBuildDir)
        try fm.createDirectory(at: safeBuildDir, withIntermediateDirectories: true, attributes: nil)

        try? _ = Utility.launch(path: "/usr/bin/make", arguments: ["clean"], currentDirectoryURL: safeBuildDir, environment: environ)
        try? _ = Utility.launch(path: "/usr/bin/make", arguments: ["distclean"], currentDirectoryURL: safeBuildDir, environment: environ)

        var args = arguments(platform: platform, arch: arch).filter { !$0.hasPrefix("--prefix=") }
        args.append("--prefix=\(safePrefix.path)")

        // Prevent SIGPIPE in autoconf configure scripts: when running inside the Swift Package
        // Plugin context, stdout is redirected to a file but stderr is not, creating an unusual
        // fd environment. GMP's configure traps SIGPIPE from its makeinfo version-check pipe.
        // Setting MAKEINFO=: disables the makeinfo check entirely, avoiding the SIGPIPE.
        environ["MAKEINFO"] = ":"

        let configure = safeSource + "configure"
        try Utility.launch(executableURL: configure, arguments: args, currentDirectoryURL: safeBuildDir, environment: environ)

        if let hook = postConfigure { try hook() }

        try Utility.launch(path: "/usr/bin/make", arguments: ["-j8"], currentDirectoryURL: safeBuildDir, environment: environ)
        try Utility.launch(path: "/usr/bin/make", arguments: ["-j8", "install"], currentDirectoryURL: safeBuildDir, environment: environ)

        // Copy from no-space prefix to the real thinDir.
        let realPrefix = thinDir(platform: platform, arch: arch)
        try? fm.removeItem(at: realPrefix)
        // Ensure the parent directory (e.g. .../thin/) exists before copying.
        try? fm.createDirectory(at: realPrefix.deletingLastPathComponent(),
                                withIntermediateDirectories: true,
                                attributes: nil)
        try fm.copyItem(at: safePrefix, to: realPrefix)
    }
}

///
/// https://github.com/xbmc/xbmc/blob/8d852242b8fed6fc99132c5428e1c703970f7201/tools/depends/target/samba-gplv3/Makefile
class BuildSmbclient: BaseBuild {
    init() {
        super.init(library: .libsmbclient)
    }

    private func writeCrossAnswers(in sourceRoot: URL, arch: ArchType) throws {
        let machine = arch.rawValue
        // Keep runtime probes enabled and answer cross-execute questions explicitly.
        // These are the critical probes that otherwise return UNKNOWN and fail configure.
        let lines = [
            "Checking uname sysname type: \"Darwin\"",
            "Checking uname machine type: \"\(machine)\"",
            "Checking uname release type: \"0\"",
            "Checking uname version type: \"0\"",
            "rpath library support: NO",
            "Checking for HAVE_SECURE_MKSTEMP: OK",
            "Checking getconf LFS_CFLAGS: NO",
            "Checking getconf large file support flags work: NO",
            "Checking for large file support without additional flags: OK",
            "Checking for -D_FILE_OFFSET_BITS=64: OK",
            "Checking for -D_LARGE_FILES: NO",
            "Checking whether setreuid is available: OK",
            "Checking whether setresuid is available: NO",
            "Checking whether seteuid is available: OK",
            "Checking whether fcntl locking is available: OK",
            "Checking correct behavior of strtoll: OK",
            "Checking for working strptime: OK",
            "Checking for C99 vsnprintf: OK",
            "Checking for HAVE_SHARED_MMAP: NO",
            "Checking for HAVE_INCOHERENT_MMAP: NO",
            "Checking for HAVE_IFACE_GETIFADDRS: NO",
            "Checking for HAVE_IFACE_AIX: NO",
            "Checking for HAVE_IFACE_IFCONF: NO",
            "Checking value of NSIG: \"32\"",
            "Checking for a 64-bit host to support lmdb: NO",
            "Checking for *bsd style statfs with statfs.f_iosize: NO",
            "Checking errno of iconv for illegal multibyte sequence: NO",
            "Checking if can we convert from CP850 to UCS-2LE: NO",
            "Checking if can we convert from IBM850 to UCS-2LE: NO",
            "Checking if can we convert from UTF-8 to UCS-2LE: NO",
            "Checking if can we convert from UTF8 to UCS-2LE: NO",
            "Checking whether fcntl lock supports open file description locks: NO",
            "Checking for the maximum value of the 'time_t' type: \"9223372036854775807\"",
            "Checking whether the realpath function allows a NULL argument: NO",
            "Checking for ftruncate extend: NO",
            "Checking for readlink breakage: NO",
            "getcwd takes a NULL argument: NO",
            "Checking for gnutls fips mode support: NO",
        ]
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(toFile: (sourceRoot + "cross-answers.txt").path, atomically: true, encoding: .utf8)
    }

    /// Creates a wrapper script at `directory/asn1_compile` that:
    ///   1. Runs the real asn1_compile binary (copied to `directory/asn1_compile_real`)
    ///   2. Renames the `.x` → `.c` and `.hx` → `.h` output files Samba 4.24.1 expects
    ///   3. Creates any missing `*_oids.c` placeholder that Samba's waf tracks as an output
    private func writeAsn1WrapperScript(in directory: URL) throws {
        let fm = FileManager.default
        let realBinDest = directory + "asn1_compile_real"
        let legacyBinDest = directory + "asn1_compile_legacy"
        try? fm.removeItem(at: realBinDest)
        try? fm.removeItem(at: legacyBinDest)
        // Keep two compilers available:
        // - system Heimdal for digest.asn1 (bundled one segfaults there)
        // - bundled Samba compiler for all other ASN.1 modules
        let pluginBin = URL.currentDirectory
            .appendingPathComponent("../Plugins/BuildFFmpeg/\(library.rawValue)/bin/asn1_compile")
            .standardized
        let systemBins = [
            "/opt/homebrew/opt/heimdal/libexec/heimdal/asn1_compile",
            "/usr/local/opt/heimdal/libexec/heimdal/asn1_compile",
            "/opt/homebrew/Cellar/heimdal/7.8.0_1/libexec/heimdal/asn1_compile",
        ]
        if let selected = systemBins.first(where: { fm.fileExists(atPath: $0) }) {
            try fm.copyItem(atPath: selected, toPath: realBinDest.path)
        } else if fm.fileExists(atPath: pluginBin.path) {
            // Fallback if system Heimdal is unavailable.
            try fm.copyItem(atPath: pluginBin.path, toPath: realBinDest.path)
        }
        if fm.fileExists(atPath: pluginBin.path) {
            try fm.copyItem(atPath: pluginBin.path, toPath: legacyBinDest.path)
        }

        let realBinPath = realBinDest.path
        let legacyBinPath = legacyBinDest.path
        let wrapperScript = #"""
        #!/bin/bash
        # Wrapper: runs the real asn1_compile then renames .x/.hx -> .c/.h
        # so Samba 4.24.1's waf finds the expected .c/.h output files.
        # Hybrid strategy:
        # - use bundled compiler for most modules (better Samba compatibility)
        # - use system compiler only for digest.asn1 (bundled one crashes there)
        args=()
        skip_next=0
        maybe_drop_next=0
        temp_opts=()
        compiler="\#(realBinPath)"

        use_system=1
        for a in "$@"; do
            case "$a" in
                *digest.asn1|*hdb.asn1)
                    use_system=1
                    break
                    ;;
                *.asn1)
                    use_system=0
                    ;;
            esac
        done
        if [ $use_system -eq 0 ] && [ -x "\#(legacyBinPath)" ]; then
            compiler="\#(legacyBinPath)"
        fi

        rewrite_opt() {
            local src="$1"
            local dst
            dst="$(mktemp "${TMPDIR:-/tmp}/asn1-opt.XXXXXX")"
            grep -v '^--decorate=' "$src" > "$dst"
            temp_opts+=("$dst")
            printf '%s\n' "$dst"
        }
        cleanup() {
            local f
            for f in "${temp_opts[@]}"; do
                [ -n "$f" ] && [ -f "$f" ] && rm -f -- "$f"
            done
        }
        trap cleanup EXIT
        if [ "$compiler" = "\#(realBinPath)" ]; then
            # System compiler path: filter unsupported options.
            for a in "$@"; do
                if [ $skip_next -eq 1 ]; then
                    skip_next=0
                    continue
                fi
                if [ $maybe_drop_next -eq 1 ]; then
                    maybe_drop_next=0
                    case "$a" in
                        *hdb.opt)
                            continue
                            ;;
                        *)
                            args+=("--option-file")
                            a="$(rewrite_opt "$a")"
                            ;;
                    esac
                fi
                case "$a" in
                    --option-file=*hdb.opt)
                        continue
                        ;;
                    --option-file=*)
                        opt_path="${a#--option-file=}"
                        args+=("--option-file=$(rewrite_opt "$opt_path")")
                        continue
                        ;;
                    --option-file)
                        maybe_drop_next=1
                        continue
                        ;;
                esac
                args+=("$a")
            done
        else
            # Bundled compiler path: strip --decorate= lines from option files
            # (legacy compiler does not support --decorate).
            for a in "$@"; do
                if [ $maybe_drop_next -eq 1 ]; then
                    maybe_drop_next=0
                    args+=("$(rewrite_opt "$a")")
                    continue
                fi
                case "$a" in
                    --option-file=*)
                        opt_path="${a#--option-file=}"
                        args+=("--option-file=$(rewrite_opt "$opt_path")")
                        continue
                        ;;
                    --option-file)
                        maybe_drop_next=1
                        args+=("--option-file")
                        continue
                        ;;
                esac
                args+=("$a")
            done
        fi

        # Avoid stale mixed outputs (e.g. .c from one compiler and .h from another)
        # when waf re-processes the same ASN.1 target in incremental cycles.
        outbase="${args[@]: -1}"
        if [ -n "$outbase" ]; then
            rm -f -- "asn1_${outbase}.c" "${outbase}.h" "${outbase}.hx" \
                "${outbase}-priv.h" "${outbase}-priv.hx" \
                "${outbase}.x" "${outbase}_oids.c"
        fi

        "$compiler" "${args[@]}"
        rc=$?
        [ $rc -ne 0 ] && exit $rc

        # Normalize one-code-file output names expected by Samba's waf.
        for f in *.x; do
            [ -f "$f" ] || continue
            mv -f -- "$f" "${f%.x}.c"
        done
        for f in *.hx; do
            [ -f "$f" ] || continue
            mv -f -- "$f" "${f%.hx}.h"
        done

        # Some system asn1 outputs omit *_oids.c for one-code-file modules;
        # waf still tracks them as expected targets.
        for c in asn1_*.c; do
            [ -f "$c" ] || continue
            stem="${c#asn1_}"
            stem="${stem%.c}"
            [ -f "${stem}_oids.c" ] || : > "${stem}_oids.c"

            # Fix ABI mismatch: system Heimdal 7.8.0 emits asn1_type_func structs
            # with 6 fields (no print callback), but Samba's bundled template engine
            # declares 7 fields (encode/decode/length/copy/release/print/size).
            # Insert a NULL print callback before the sizeof field.
            python3 - "$c" "${stem}.h" "${stem}-priv.h" <<'PYEOF'
        import os, re, sys

        c_path = sys.argv[1]
        c_data = open(c_path).read()
        c_data = re.sub(
            r'(\(asn1_type_release\)[^\n]+,\n)(\s+)(sizeof\()',
            r'\1\2NULL,\n\2\3',
            c_data
        )

        # Normalize HEIM_ANY API/type names emitted by legacy/system compilers
        # to the lower-case symbols expected by Samba's bundled headers.
        c_data = c_data.replace('encode_HEIM_ANY', 'encode_heim_any')
        c_data = c_data.replace('decode_HEIM_ANY', 'decode_heim_any')
        c_data = c_data.replace('length_HEIM_ANY', 'length_heim_any')
        c_data = c_data.replace('copy_HEIM_ANY', 'copy_heim_any')
        c_data = c_data.replace('free_HEIM_ANY', 'free_heim_any')
        c_data = c_data.replace('sizeof(HEIM_ANY)', 'sizeof(heim_any)')
        c_data = c_data.replace('encode_HEIM_ANY_SET', 'encode_heim_any_set')
        c_data = c_data.replace('decode_HEIM_ANY_SET', 'decode_heim_any_set')
        c_data = c_data.replace('length_HEIM_ANY_SET', 'length_heim_any_set')
        c_data = c_data.replace('copy_HEIM_ANY_SET', 'copy_heim_any_set')
        c_data = c_data.replace('free_HEIM_ANY_SET', 'free_heim_any_set')
        c_data = c_data.replace('encode_heim_any_SET', 'encode_heim_any_set')
        c_data = c_data.replace('decode_heim_any_SET', 'decode_heim_any_set')
        c_data = c_data.replace('length_heim_any_SET', 'length_heim_any_set')
        c_data = c_data.replace('copy_heim_any_SET', 'copy_heim_any_set')
        c_data = c_data.replace('free_heim_any_SET', 'free_heim_any_set')
        c_data = c_data.replace('sizeof(HEIM_ANY_SET)', 'sizeof(heim_any_set)')
        c_data = c_data.replace('offsetof(EnvelopedData_originatorInfo,', 'offsetof(OriginatorInfo,')

        if os.path.basename(c_path) == 'asn1_rfc2459_asn1.c':
            # Legacy asn1 compiler emits a few invalid type references for rfc2459.
            # Rewrite them to the concrete types present in generated headers.
            # Some generator outputs use "struct" for typedef-only types.
            c_data = c_data.replace('offsetof(struct AlgorithmIdentifier,', 'offsetof(AlgorithmIdentifier,')
            c_data = c_data.replace('offsetof(struct SubjectPublicKeyInfo,', 'offsetof(SubjectPublicKeyInfo,')
            c_data = c_data.replace('offsetof(struct TBSCertificate,', 'offsetof(TBSCertificate,')
            c_data = c_data.replace('offsetof(struct Certificate,', 'offsetof(Certificate,')
            c_data = c_data.replace('offsetof(struct DigestInfo,', 'offsetof(DigestInfo,')
            c_data = c_data.replace('offsetof(struct TBSCRLCertList,', 'offsetof(TBSCRLCertList,')
            c_data = c_data.replace('offsetof(struct CRLCertificateList,', 'offsetof(CRLCertificateList,')
            c_data = re.sub(r'offsetof\(([A-Za-z0-9_]+_val),', r'offsetof(struct \1,', c_data)

            c_data = c_data.replace('offsetof(DistributionPoint, element)', 'offsetof(DistributionPointName, element)')
            c_data = c_data.replace('offsetof(DistributionPoint, u.fullName)', 'offsetof(DistributionPointName, u.fullName)')
            c_data = c_data.replace('offsetof(DistributionPoint, u.nameRelativeToCRLIssuer)', 'offsetof(DistributionPointName, u.nameRelativeToCRLIssuer)')

            c_data = c_data.replace('CommonCriteriaMeasures_profileUri', 'URIReference')
            c_data = c_data.replace('CommonCriteriaMeasures_targetUri', 'URIReference')

        open(c_path, 'w').write(c_data)

        for h_path in sys.argv[2:]:
            if not os.path.exists(h_path):
                continue
            h_data = open(h_path).read()
            h_data = h_data.replace('HEIM_ANY_SET', 'heim_any_set')
            h_data = h_data.replace('heim_any_SET', 'heim_any_set')
            h_data = h_data.replace('HEIM_ANY', 'heim_any')
            if os.path.basename(h_path) == 'krb5_asn1.h':
                h_data = h_data.replace(
                    '  int kdc_issued_verified;\n  AuthorizationData *want_ad;\n} PrincipalNameAttrs;',
                    '  int kdc_issued_verified;\n  AuthorizationData *want_ad;\n  void *pac;\n} PrincipalNameAttrs;'
                )
            open(h_path, 'w').write(h_data)
        PYEOF
        done

        exit 0
        """#
        let wrapperPath = (directory + "asn1_compile").path
        try wrapperScript.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: wrapperPath)
    }

    private func patchEmbeddedHeimdalConfig(in sourceRoot: URL) throws {
        let file = (sourceRoot + "wscript_configure_embedded_heimdal").path
        guard var text = try? String(contentsOfFile: file, encoding: .utf8) else {
            return
        }
        if text.contains("check_system_heimdal_binary") {
            return
        }
        let needle = "conf.RECURSE('third_party/heimdal_build')\n"
        guard let range = text.range(of: needle) else {
            return
        }
        let inject = """
        
        def check_system_heimdal_binary(name):
            if not conf.find_program(name, var=name.upper()):
                return False
            conf.define('USING_SYSTEM_%s' % name.upper(), 1)
            return True

        check_system_heimdal_binary('compile_et')
        check_system_heimdal_binary('asn1_compile')
        """
        text.replaceSubrange(range.upperBound..<range.upperBound, with: inject)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchVisionOSIncompatibilities(in sourceRoot: URL) throws {
        let faultFile = (sourceRoot + "lib/util/fault.c").path
        guard var text = try? String(contentsOfFile: faultFile, encoding: .utf8) else {
            return
        }

        // system() is unavailable on visionOS. Keep behavior predictable by
        // returning an error code instead of invoking it.
        if text.contains("result = system(cmdstring);") {
            text = text.replacingOccurrences(of: "result = system(cmdstring);",
                                             with: "result = -1; /* system() unavailable on visionOS */")
            try text.write(toFile: faultFile, atomically: true, encoding: .utf8)
        }

        let utilFile = (sourceRoot + "source3/lib/util.c").path
        if var utilText = try? String(contentsOfFile: utilFile, encoding: .utf8) {
            if utilText.contains("result = system(cmd);") {
                utilText = utilText.replacingOccurrences(of: "result = system(cmd);",
                                                         with: "result = -1; /* system() unavailable on visionOS */")
                try utilText.write(toFile: utilFile, atomically: true, encoding: .utf8)
            }
        }

        let localNpFile = (sourceRoot + "source3/rpc_client/local_np.c").path
        if var localNpText = try? String(contentsOfFile: localNpFile, encoding: .utf8) {
            if !localNpText.contains("#include <crt_externs.h>") {
                localNpText = localNpText.replacingOccurrences(of: "#include <spawn.h>\n",
                                                               with: "#include <spawn.h>\n#include <crt_externs.h>\n")
                try localNpText.write(toFile: localNpFile, atomically: true, encoding: .utf8)
            }
        }
    }

    private func patchHx509ForFlattenedRfc2459(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/hx509/cert.c").path
        guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        // Legacy ASN.1 flattening removes generated _ioschoice wrappers from
        // Extension and OtherName. Switch hx509 lookups to extnID/type_id checks
        // and use raw OCTET STRING payloads.
        text = text.replacingOccurrences(of:
            """
        if (ext->_ioschoice_extnValue.element !=
            choice_Extension_iosnumunknown &&
            ext->_ioschoice_extnValue.element !=
            choice_Extension_iosnum_id_heim_ce_pkinit_princ_max_life)
            continue;
        if (ext->_ioschoice_extnValue.element == choice_Extension_iosnumunknown &&
            der_heim_oid_cmp(&asn1_oid_id_heim_ce_pkinit_princ_max_life, &ext->extnID))
            continue;
        if (ext->_ioschoice_extnValue.u.ext_HeimPkinitPrincMaxLife) {
            r = *ext->_ioschoice_extnValue.u.ext_HeimPkinitPrincMaxLife;
        } else {
""",
            with:
            """
        if (der_heim_oid_cmp(&asn1_oid_id_heim_ce_pkinit_princ_max_life, &ext->extnID))
            continue;
        {
""")

        text = text.replacingOccurrences(of:
            """
    if (sid_ext.val[0].u.otherName._ioschoice_value.element !=
	choice_OtherName_iosnum_szOID_NTDS_OBJECTSID)
    {
        free_SidExtension(&sid_ext);
        return HX509_CMS_INVALID_DATA;
    }

    if (!sid_ext.val[0].u.otherName._ioschoice_value.u.on_ntds_objectsid) {
        free_SidExtension(&sid_ext);
        return HX509_CMS_INVALID_DATA;
    }

    ret = der_copy_octet_string(
        sid_ext.val[0].u.otherName._ioschoice_value.u.on_ntds_objectsid, sid);
    free_SidExtension(&sid_ext);
    return ret;
""",
            with:
            """
    if (der_heim_oid_cmp(&asn1_oid_szOID_NTDS_OBJECTSID,
                         &sid_ext.val[0].u.otherName.type_id)) {
        free_SidExtension(&sid_ext);
        return HX509_CMS_INVALID_DATA;
    }

    if (!sid_ext.val[0].u.otherName.value) {
        free_SidExtension(&sid_ext);
        return HX509_CMS_INVALID_DATA;
    }

    ret = der_copy_octet_string(sid_ext.val[0].u.otherName.value, sid);
    free_SidExtension(&sid_ext);
    return ret;
""")

        text = text.replacingOccurrences(of: "add_to_list(list, &sa.val[j].u.otherName.value);",
                                         with: "add_to_list(list, sa.val[j].u.otherName.value);")
        text = text.replacingOccurrences(of: "heim_any_cmp(&c->u.otherName.value,",
                                         with: "heim_any_cmp(c->u.otherName.value,")
        text = text.replacingOccurrences(of: "&n->u.otherName.value) != 0)",
                                         with: "n->u.otherName.value) != 0)")

        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchHx509PrivateKeyPrototype(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/hx509/hx_locl.h").path
        guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        let marker = "typedef void (*_hx509_cert_release_func)(struct hx509_cert_data *, void *);\n"
        let decl = "hx509_private_key _hx509_cert_private_key(hx509_cert p);\n"
        if text.contains(marker) && !text.contains(decl) {
            text = text.replacingOccurrences(of: marker, with: marker + decl)
            try text.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    private func patchHx509CaForFlattenedRfc2459(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/hx509/ca.c").path
        guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        text = text.replacingOccurrences(
            of: "\tASN1_MALLOC_ENCODE(CPSuri,\n\t\t\t   pqi.qualifier.data,\n\t\t\t   pqi.qualifier.length,\n\t\t\t   &uri, &size, ret);\n        if (ret == 0) {\n            ret = add_PolicyQualifierInfos(&pqis, &pqi);\n            free_heim_any(&pqi.qualifier);\n        }",
            with: "        {\n            heim_octet_string qualifier;\n\t    ASN1_MALLOC_ENCODE(CPSuri,\n\t\t\t       qualifier.data,\n\t\t\t       qualifier.length,\n\t\t\t       &uri, &size, ret);\n            if (ret == 0) {\n                pqi.qualifier = &qualifier;\n                ret = add_PolicyQualifierInfos(&pqis, &pqi);\n                free_heim_any(&qualifier);\n                pqi.qualifier = NULL;\n            }\n        }"
        )

        text = text.replacingOccurrences(
            of: "\tASN1_MALLOC_ENCODE(UserNotice,\n\t\t\t   pqi.qualifier.data,\n\t\t\t   pqi.qualifier.length,\n\t\t\t   &un, &size, ret);\n        if (ret == 0) {\n            ret = add_PolicyQualifierInfos(&pqis, &pqi);\n            free_heim_any(&pqi.qualifier);\n        }",
            with: "        {\n            heim_octet_string qualifier;\n\t    ASN1_MALLOC_ENCODE(UserNotice,\n\t\t\t       qualifier.data,\n\t\t\t       qualifier.length,\n\t\t\t       &un, &size, ret);\n            if (ret == 0) {\n                pqi.qualifier = &qualifier;\n                ret = add_PolicyQualifierInfos(&pqis, &pqi);\n                free_heim_any(&qualifier);\n                pqi.qualifier = NULL;\n            }\n        }"
        )

        text = text.replacingOccurrences(of: "    gn.u.otherName.value = *os;",
                                         with: "    gn.u.otherName.value = rk_UNCONST(os);")

        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchHx509ReqForFlattenedRfc2459(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/hx509/req.c").path
        guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        text = text.replacingOccurrences(of:
            """
    const PKIXXmppAddr us = (const PKIXXmppAddr)(uintptr_t)s;
    GeneralName gn;
    size_t size;
    int ret;

    gn.element = choice_GeneralName_otherName;
    gn.u.otherName.type_id.length = 0;
    gn.u.otherName.type_id.components = 0;
    gn.u.otherName.value.data = NULL;
    gn.u.otherName.value.length = 0;
    ret = der_copy_oid(oid, &gn.u.otherName.type_id);
    if (ret == 0)
        ASN1_MALLOC_ENCODE(PKIXXmppAddr, gn.u.otherName.value.data,
                           gn.u.otherName.value.length, &us, &size, ret);
    if (ret == 0 && size != gn.u.otherName.value.length)
        _hx509_abort("internal ASN.1 encoder error");
""",
            with:
            """
    const PKIXXmppAddr us = (const PKIXXmppAddr)(uintptr_t)s;
    GeneralName gn;
    heim_octet_string value;
    size_t size;
    int ret;

    memset(&value, 0, sizeof(value));
    gn.element = choice_GeneralName_otherName;
    gn.u.otherName.type_id.length = 0;
    gn.u.otherName.type_id.components = 0;
    gn.u.otherName.value = &value;
    ret = der_copy_oid(oid, &gn.u.otherName.type_id);
    if (ret == 0)
        ASN1_MALLOC_ENCODE(PKIXXmppAddr, gn.u.otherName.value->data,
                           gn.u.otherName.value->length, &us, &size, ret);
    if (ret == 0 && size != gn.u.otherName.value->length)
        _hx509_abort("internal ASN.1 encoder error");
""")

        text = text.replacingOccurrences(of:
            """
    SRVName n;
    size_t size;
    int ret;

    memset(&n, 0, sizeof(n));
    memset(&gn, 0, sizeof(gn));
    gn.element = choice_GeneralName_otherName;
    gn.u.otherName.type_id.length = 0;
    gn.u.otherName.type_id.components = 0;
    gn.u.otherName.value.data = NULL;
    gn.u.otherName.value.length = 0;
    n.length = strlen(dnssrv);
    n.data = (void *)(uintptr_t)dnssrv;
    ASN1_MALLOC_ENCODE(SRVName,
                       gn.u.otherName.value.data,
                       gn.u.otherName.value.length, &n, &size, ret);
""",
            with:
            """
    SRVName n;
    heim_octet_string value;
    size_t size;
    int ret;

    memset(&n, 0, sizeof(n));
    memset(&gn, 0, sizeof(gn));
    memset(&value, 0, sizeof(value));
    gn.element = choice_GeneralName_otherName;
    gn.u.otherName.type_id.length = 0;
    gn.u.otherName.type_id.components = 0;
    gn.u.otherName.value = &value;
    n.length = strlen(dnssrv);
    n.data = (void *)(uintptr_t)dnssrv;
    ASN1_MALLOC_ENCODE(SRVName,
                       gn.u.otherName.value->data,
                       gn.u.otherName.value->length, &n, &size, ret);
""")

        text = text.replacingOccurrences(of:
            """
    KRB5PrincipalName kn;
    GeneralName gn;
    int ret;

""",
            with:
            """
    KRB5PrincipalName kn;
    GeneralName gn;
    heim_octet_string value;
    int ret;

""")

        text = text.replacingOccurrences(of:
            """
        memset(&kn, 0, sizeof(kn));
        memset(&gn, 0, sizeof(gn));
        gn.element = choice_GeneralName_otherName;
        gn.u.otherName.type_id.length = 0;
        gn.u.otherName.type_id.components = 0;
        gn.u.otherName.value.data = NULL;
        gn.u.otherName.value.length = 0;
        ret = der_copy_oid(&asn1_oid_id_pkinit_san, &gn.u.otherName.type_id);
        if (ret == 0)
            ret = _hx509_make_pkinit_san(context, princ, &gn.u.otherName.value);
    """,
            with:
            """
        memset(&kn, 0, sizeof(kn));
        memset(&gn, 0, sizeof(gn));
        memset(&value, 0, sizeof(value));
        gn.element = choice_GeneralName_otherName;
        gn.u.otherName.type_id.length = 0;
        gn.u.otherName.type_id.components = 0;
        gn.u.otherName.value = &value;
        ret = der_copy_oid(&asn1_oid_id_pkinit_san, &gn.u.otherName.type_id);
        if (ret == 0)
            ret = _hx509_make_pkinit_san(context, princ, gn.u.otherName.value);
    """)

        text = text.replacingOccurrences(of: "san->u.otherName.value.data", with: "san->u.otherName.value->data")
        text = text.replacingOccurrences(of: "san->u.otherName.value.length", with: "san->u.otherName.value->length")
        text = text.replacingOccurrences(of: "&san->u.otherName.value", with: "san->u.otherName.value")

        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchHx509PrintForFlattenedRfc2459(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/hx509/print.c").path
        guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        text = text.replacingOccurrences(of: "pi->qualifier.data", with: "pi->qualifier->data")
        text = text.replacingOccurrences(of: "pi->qualifier.length", with: "pi->qualifier->length")

        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchKrb5PrincipalForCompositeNameattrs(in sourceRoot: URL) throws {
        let headerFile = (sourceRoot + "third_party/heimdal/lib/krb5/krb5.h").path
        if var text = try? String(contentsOfFile: headerFile, encoding: .utf8) {
            text = text.replacingOccurrences(of: "typedef Principal krb5_principal_data;", with: "typedef CompositePrincipal krb5_principal_data;")
            text = text.replacingOccurrences(of: "typedef struct Principal *krb5_principal;", with: "typedef struct CompositePrincipal *krb5_principal;")
            text = text.replacingOccurrences(of: "typedef const struct Principal *krb5_const_principal;", with: "typedef const struct CompositePrincipal *krb5_const_principal;")
            try text.write(toFile: headerFile, atomically: true, encoding: .utf8)
        }

        let principalFile = (sourceRoot + "third_party/heimdal/lib/krb5/principal.c").path
        if var text = try? String(contentsOfFile: principalFile, encoding: .utf8) {
            text = text.replacingOccurrences(of: "        free_Principal(p);", with: "        free_CompositePrincipal(p);")
            text = text.replacingOccurrences(of: "    if(copy_Principal(inprinc, p)) {", with: "    if(copy_CompositePrincipal(inprinc, p)) {")
            try text.write(toFile: principalFile, atomically: true, encoding: .utf8)
        }

        let pacFile = (sourceRoot + "third_party/heimdal/lib/krb5/pac.c").path
        if var text = try? String(contentsOfFile: pacFile, encoding: .utf8) {
            text = text.replacingOccurrences(of: "        free_Principal(pac->upn_princ);", with: "        free_CompositePrincipal(pac->upn_princ);")
            text = text.replacingOccurrences(of: "        free_Principal(pac->canon_princ);", with: "        free_CompositePrincipal(pac->canon_princ);")
            try text.write(toFile: pacFile, atomically: true, encoding: .utf8)
        }
    }

    private func patchHeimdalGssapiForCompositePrincipal(in sourceRoot: URL) throws {
        let publicHeader = (sourceRoot + "third_party/heimdal/lib/gssapi/gssapi/gssapi_krb5.h").path
        if var text = try? String(contentsOfFile: publicHeader, encoding: .utf8) {
            text = text.replacingOccurrences(of: "struct Principal;", with: "struct CompositePrincipal;")
            text = text.replacingOccurrences(of: "struct Principal * /*keytab_principal*/,", with: "struct CompositePrincipal * /*keytab_principal*/,")
            try text.write(toFile: publicHeader, atomically: true, encoding: .utf8)
        }

        let localHeader = (sourceRoot + "third_party/heimdal/lib/gssapi/krb5/gsskrb5_locl.h").path
        if var text = try? String(contentsOfFile: localHeader, encoding: .utf8) {
            text = text.replacingOccurrences(of: "typedef struct Principal *gsskrb5_name;", with: "typedef krb5_principal gsskrb5_name;")
            try text.write(toFile: localHeader, atomically: true, encoding: .utf8)
        }
    }

    private func patchRfc2459ForLegacyAsn1(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/asn1/rfc2459.asn1").path
        guard var t = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        // System asn1_compile (Homebrew Heimdal 7.7) does not support ASN.1 CLASS or
        // parameterized types.  We remove all CLASS definitions and replace parameterized
        // type bodies with simple concrete equivalents that are structurally equivalent
        // for the fields actually accessed by Samba.

        // --- Remove CLASS definitions ---
        t = t.replacingOccurrences(of:
            "_OTHER-NAME ::= CLASS {\n    &id OBJECT IDENTIFIER UNIQUE,\n    &Type\n}",
            with: "-- _OTHER-NAME ::= CLASS { ... } (removed for legacy asn1_compile)")
        t = t.replacingOccurrences(of:
            "_ATTRIBUTE ::= CLASS {\n    &id             OBJECT IDENTIFIER UNIQUE,\n    &Type           OPTIONAL,\n -- &equality-match MATCHING-RULE OPTIONAL,\n    &minCount       INTEGER DEFAULT 1,\n    &maxCount       INTEGER OPTIONAL\n}",
            with: "-- _ATTRIBUTE ::= CLASS { ... } (removed for legacy asn1_compile)")
        t = t.replacingOccurrences(of:
            "_EXTENSION ::= CLASS {\n    &id  OBJECT IDENTIFIER UNIQUE,\n    &ExtnType,\n    &Critical    BOOLEAN DEFAULT FALSE\n}",
            with: "-- _EXTENSION ::= CLASS { ... } (removed for legacy asn1_compile)")
        t = t.replacingOccurrences(of:
            "_POLICYQUALIFIERINFO ::= CLASS { -- Heimdal extension\n    &id  OBJECT IDENTIFIER UNIQUE,\n    &Type\n}",
            with: "-- _POLICYQUALIFIERINFO ::= CLASS { ... } (removed for legacy asn1_compile)")

        // --- Replace parameterized type definitions with concrete equivalents ---
        // OtherName: defer concrete definition to the alias site at end of file.
        t = t.replacingOccurrences(of:
            "OtherName{_OTHER-NAME:OtherNameSet} ::= SEQUENCE {\n    type-id     _OTHER-NAME.&id({OtherNameSet}),\n    value       [0] _OTHER-NAME.&Type({OtherNameSet}{@type-id})\n}",
            with: "-- OtherName parameterized removed (concrete definition at end of file)")
        // SingleAttribute/AttributeSet: define in-place so they appear before
        // SubjectDirectoryAttributes which references AttributeSet.
        t = t.replacingOccurrences(of:
            "SingleAttribute{_ATTRIBUTE:AttrSet} ::= SEQUENCE {\n    type      _ATTRIBUTE.&id({AttrSet}),\n    value     _ATTRIBUTE.&Type({AttrSet}{@type})\n}",
            with: "SingleAttribute ::= SEQUENCE {\n    type    OBJECT IDENTIFIER,\n    value   OCTET STRING OPTIONAL\n}")
        t = t.replacingOccurrences(of:
            "AttributeSet{_ATTRIBUTE:AttrSet} ::= SEQUENCE {\n    type      _ATTRIBUTE.&id({AttrSet}),\n    values    SET --SIZE (1..MAX)-- OF _ATTRIBUTE.&Type({AttrSet}{@type})\n}",
            with: "AttributeSet ::= SEQUENCE {\n    type    OBJECT IDENTIFIER,\n    values  SET OF OCTET STRING\n}")
        // Extension: define in-place so it appears before Extensions (SEQUENCE OF Extension).
        t = t.replacingOccurrences(of:
            "Extension{_EXTENSION:ExtensionSet} ::= SEQUENCE {\n    extnID      _EXTENSION.&id({ExtensionSet}),\n    critical    BOOLEAN\n--                     (EXTENSION.&Critical({ExtensionSet}{@extnID}))\n                     DEFAULT FALSE,\n    extnValue   OCTET STRING (CONTAINING\n                _EXTENSION.&ExtnType({ExtensionSet}{@extnID}))\n}",
            with: "Extension ::= SEQUENCE {\n    extnID      OBJECT IDENTIFIER,\n    critical    BOOLEAN DEFAULT FALSE,\n    extnValue   OCTET STRING\n}")
        // PolicyQualifierInfo: only definition; replace with concrete version.
        t = t.replacingOccurrences(of:
            "PolicyQualifierInfo{_POLICYQUALIFIERINFO:PolicyQualifierSet} ::= SEQUENCE {\n    policyQualifierId   _POLICYQUALIFIERINFO.&id({PolicyQualifierSet}),\n    qualifier _POLICYQUALIFIERINFO.&Type({PolicyQualifierSet}{@policyQualifierId})\n}",
            with: "PolicyQualifierInfo ::= SEQUENCE {\n    policyQualifierId   OBJECT IDENTIFIER,\n    qualifier           OCTET STRING OPTIONAL\n}")

        // --- Comment out all IOS object-set instance definitions ---
        // Matches: on-*/at-*/ext-*/pq-* <CLASS> ::= { ... }  and named sets.
        // The pattern allows one level of nested { } to handle inline ASN.1 comments
        // like --{ub-state-name}-- that appear inside single-line instance bodies.
        let instancePattern = #"^((?:on|at|ext|pq)-[\w-]+\s+_(?:OTHER-NAME|ATTRIBUTE|EXTENSION|POLICYQUALIFIERINFO)|KnownOtherNameTypes\s+_OTHER-NAME|SupportedAttributes\s+_ATTRIBUTE|CertExtensions\s+_EXTENSION|KnownPolicyQualifiers\s+_POLICYQUALIFIERINFO)\s*::=\s*\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}"#
        if let regex = try? NSRegularExpression(pattern: instancePattern, options: [.anchorsMatchLines]) {
            let range = NSRange(t.startIndex..., in: t)
            t = regex.stringByReplacingMatches(in: t, range: range, withTemplate: "-- $1 ::= { ... }")
        }

        // Also replace the concrete PolicyQualifierInfo alias at end of file
        t = t.replacingOccurrences(of:
            "PolicyQualifierInfo ::= PolicyQualifierInfo{KnownPolicyQualifiers}",
            with: "-- PolicyQualifierInfo already defined above")

        // --- Replace concrete alias lines at end of file ---
        // Define OtherName before GeneralName (legacy compiler may emit GeneralName
        // before resolving the alias at end-of-file, causing header type ordering issues).
        let concreteOtherName = "OtherName ::= SEQUENCE {\n    type-id     OBJECT IDENTIFIER,\n    value       [0] OCTET STRING OPTIONAL\n}"
        if t.contains("GeneralName ::= CHOICE {") && !t.contains(concreteOtherName + "\n\nGeneralName ::= CHOICE {") {
            t = t.replacingOccurrences(of: "GeneralName ::= CHOICE {",
                                        with: concreteOtherName + "\n\nGeneralName ::= CHOICE {")
        }
        t = t.replacingOccurrences(of:
            "OtherName ::= OtherName{KnownOtherNameTypes}",
            with: "-- OtherName already defined above")
        // Keep HEIM_ANY import valid for the legacy compiler path.
        t = t.replacingOccurrences(of:
            "IMPORTS OCTET STRING FROM heim\n        PrincipalName, Realm FROM krb5;",
            with: "IMPORTS HEIM_ANY FROM heim\n        PrincipalName, Realm FROM krb5;")
        t = t.replacingOccurrences(of:
            "SingleAttribute ::= SingleAttribute{SupportedAttributes}",
            with: "-- SingleAttribute already defined above")
        t = t.replacingOccurrences(of:
            "AttributeSet ::= AttributeSet{SupportedAttributes}",
            with: "-- AttributeSet already defined above")
        t = t.replacingOccurrences(of:
            "Extension ::= Extension { CertExtensions }",
            with: "-- Extension already defined above")

        try t.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchPkcs10ForLegacyAsn1(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/asn1/pkcs10.asn1").path
        guard var t = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        t = t.replacingOccurrences(of:
            "_ATTRIBUTE ::= CLASS {\n    &id             OBJECT IDENTIFIER UNIQUE,\n    &Type           OPTIONAL,\n    &minCount       INTEGER DEFAULT 1,\n    &maxCount       INTEGER OPTIONAL\n}",
            with: "-- _ATTRIBUTE ::= CLASS { ... } (removed for legacy asn1_compile)")
        t = t.replacingOccurrences(of:
            "at-extReq _ATTRIBUTE ::= { &Type CRIExtensions, &id id-pkcs9-extReq-copy }",
            with: "-- at-extReq _ATTRIBUTE ::= { ... }")
        t = t.replacingOccurrences(of:
            "CRIAttributes _ATTRIBUTE ::= { at-extReq }",
            with: "-- CRIAttributes _ATTRIBUTE ::= { ... }")
        let concreteCRIAttributeSet = "CRIAttributeSet ::= SEQUENCE {\n    type      OBJECT IDENTIFIER,\n    values    SET OF OCTET STRING\n}"
        if t.contains("CertificationRequestInfo ::= SEQUENCE {") && !t.contains(concreteCRIAttributeSet + "\n\nCertificationRequestInfo ::= SEQUENCE {") {
            t = t.replacingOccurrences(of: "CertificationRequestInfo ::= SEQUENCE {",
                                        with: concreteCRIAttributeSet + "\n\nCertificationRequestInfo ::= SEQUENCE {")
        }
        // Keep IOSCertificationRequestInfo as a distinct type when flattening
        // parameterized definitions; otherwise IOSCertificationRequest may refer
        // to an undefined type.
        t = t.replacingOccurrences(of:
            "CertificationRequestInfo ::= SEQUENCE {\n    version       PKCS10-Version,\n    subject       Name,\n    subjectPKInfo SubjectPublicKeyInfo,\n    attributes    [0] IMPLICIT SET OF CRIAttributeSet OPTIONAL \n}",
            with: "IOSCertificationRequestInfo ::= SEQUENCE {\n    version       PKCS10-Version,\n    subject       Name,\n    subjectPKInfo SubjectPublicKeyInfo,\n    attributes    [0] IMPLICIT SET OF CRIAttributeSet OPTIONAL \n}")
        t = t.replacingOccurrences(of:
            "IOSCertificationRequestInfo ::= CertificationRequestInfo{IOSCRIAttributes}",
            with: "-- IOSCertificationRequestInfo already defined above")
        t = t.replacingOccurrences(of:
            "CRIAttributeSet{_ATTRIBUTE:AttrSet} ::= SEQUENCE {\n    type      _ATTRIBUTE.&id({AttrSet}),\n    values    SET --SIZE (1..MAX)-- OF _ATTRIBUTE.&Type({AttrSet}{@type})\n}",
            with: "-- CRIAttributeSet parameterized removed (concrete definition above)")
        t = t.replacingOccurrences(of:
            "CRIAttributeSet ::= CRIAttributeSet{CRIAttributes}",
            with: "-- CRIAttributeSet already defined above")

        try t.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchKrb5ForLegacyAsn1(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal/lib/asn1/krb5.asn1").path
        guard var t = try? String(contentsOfFile: file, encoding: .utf8) else { return }

        let principalNameAttrBlock = """
        PrincipalNameAttrSrc ::= CHOICE {
                enc-kdc-rep-part    [0] EncKDCRepPart,  -- minus session key
                enc-ticket-part     [1] EncTicketPart   -- minus session key
        }
        PrincipalNameAttrs ::= SEQUENCE {
                -- True if this name was authenticated via an AP-REQ or a KDC-REP
                authenticated       [0]     BOOLEAN,
                -- These are compiled from the Ticket, KDC-REP, and/or Authenticator
                source              [1]     PrincipalNameAttrSrc OPTIONAL,
                authenticator-ad    [2]     AuthorizationData OPTIONAL,
                -- For the server on the client side we should keep track of the
                -- transit path taken to reach it (if absent -> unknown).
                --
                -- We don't learn much more about the server from the KDC.
                peer-realm          [3]     Realm OPTIONAL,
                transited           [4]     TransitedEncoding OPTIONAL,
                -- True if the PAC was verified
                pac-verified        [5]     BOOLEAN,
                -- True if any AD-KDC-ISSUEDs in the Ticket were validated
                kdc-issued-verified [6]     BOOLEAN,
                -- TODO: Add requested attributes, for gss_set_name_attribute(), which
                --       should cause corresponding authz-data elements to be added to
                --       any TGS-REQ or to the AP-REQ's Authenticator as appropriate.
                want-ad             [7]     AuthorizationData OPTIONAL
        }
        """
        // Move PrincipalNameAttrSrc/Attrs after EncKDCRepPart using anchor-based approach
        // (avoids tab/space whitespace matching issues with the EncKDCRepPart body).
        // Also move CompositePrincipal (which uses PrincipalNameAttrs) together with the block.
        let compositePrincipalBlock = "-- This is our type for exported composite name tokens for GSS [RFC6680].\n-- It's the same as Principal (below) as decorated with (see krb5.opt file and\n-- asn1_compile usage), except it's not decorated, so the name attributes are\n-- encoded/decoded.\nCompositePrincipal ::= [APPLICATION 48] SEQUENCE {\n\tname[0]\t\t\tPrincipalName,\n\trealm[1]\t\tRealm,\n        nameattrs[2]            PrincipalNameAttrs OPTIONAL\n}"
        let encTgsAnchor = "EncTGSRepPart ::= [APPLICATION 26] EncKDCRepPart"
        if t.contains(principalNameAttrBlock) && t.contains(encTgsAnchor) {
            t = t.replacingOccurrences(of: principalNameAttrBlock, with: "")
            // Also remove CompositePrincipal from original location (if present)
            t = t.replacingOccurrences(of: "\n" + compositePrincipalBlock, with: "")
            // Insert both blocks after EncTGSRepPart
            t = t.replacingOccurrences(of: encTgsAnchor,
                                        with: encTgsAnchor + "\n\n" + principalNameAttrBlock + "\n\n" + compositePrincipalBlock)
        }

        t = t.replacingOccurrences(of:
            "KERB-ERROR-DATA ::= SEQUENCE {\n        data-type [1] KerbErrorDataType,\n        data-value [2] OCTET STRING OPTIONAL\n}\n\nKerbErrorDataType ::= INTEGER {\n        kERB-AP-ERR-TYPE-SKEW-RECOVERY(2),\n        kERB-ERR-TYPE-EXTENDED(3)\n}",
            with: "KerbErrorDataType ::= INTEGER {\n        kERB-AP-ERR-TYPE-SKEW-RECOVERY(2),\n        kERB-ERR-TYPE-EXTENDED(3)\n}\n\nKERB-ERROR-DATA ::= SEQUENCE {\n        data-type [1] KerbErrorDataType,\n        data-value [2] OCTET STRING OPTIONAL\n}")

        // Fix S4UUserID ordering: move S4UUserID definition before PA-S4U-X509-USER.
        // File uses 8-space indentation.
        let s4uUserBlock = "PA-S4U-X509-USER::= SEQUENCE {\n\tuser-id[0] S4UUserID,\n\tchecksum[1] Checksum\n}\n\nS4UUserID ::= SEQUENCE {\n\tnonce [0] Krb5UInt32, -- the nonce in KDC-REQ-BODY\n\tcname [1] PrincipalName OPTIONAL, -- Certificate mapping hints\n\tcrealm [2] Realm,\n\tsubject-certificate [3] OCTET STRING OPTIONAL,\n\toptions [4] BIT STRING OPTIONAL,\n\t...\n}"
        let s4uUserFixed = "S4UUserID ::= SEQUENCE {\n\tnonce [0] Krb5UInt32, -- the nonce in KDC-REQ-BODY\n\tcname [1] PrincipalName OPTIONAL, -- Certificate mapping hints\n\tcrealm [2] Realm,\n\tsubject-certificate [3] OCTET STRING OPTIONAL,\n\toptions [4] BIT STRING OPTIONAL,\n\t...\n}\n\nPA-S4U-X509-USER::= SEQUENCE {\n\tuser-id[0] S4UUserID,\n\tchecksum[1] Checksum\n}"
        t = t.replacingOccurrences(of: s4uUserBlock, with: s4uUserFixed)

        try t.write(toFile: file, atomically: true, encoding: .utf8)
    }

    private func patchHeimdalAsn1SourcesForDisabledKx509(in sourceRoot: URL) throws {
        let files = [
            (sourceRoot + "third_party/heimdal/lib/asn1/oid_resolution.c").path,
            (sourceRoot + "third_party/heimdal/lib/asn1/asn1_print.c").path,
        ]

        for file in files {
            guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            text = text.replacingOccurrences(of: "#include \"kx509_asn1.h\"\n", with: "")
            text = text.replacingOccurrences(of: "#include \"kx509_asn1_oids.c\"\n", with: "")
            text = text.replacingOccurrences(of: "#include \"kx509_asn1_syms.c\"\n", with: "")
            try text.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    private func patchHeimdalKx509ForVisionOS(in sourceRoot: URL) throws {
        let file = (sourceRoot + "third_party/heimdal_build/wscript_build").path
        guard var text = try? String(contentsOfFile: file, encoding: .utf8) else {
            return
        }

        // Ensure hostcc tasks emit macOS binaries even when cross-target CFLAGS
        // leak into the environment. Append host target flags at the end so they
        // take precedence over earlier -target values.
        let cflagsNeedle = """
    cflags = ''
    cflags_end = cflags_picky + cflags_unpicky + extra_cflags
    return (cflags, cflags_end, allow_warnings)
"""
        let cflagsReplacement = """
    cflags = ''
    cflags_end = cflags_picky + cflags_unpicky + extra_cflags
    if use_hostcc:
        cflags_end += ['-target', 'arm64-apple-macos13.0']
    return (cflags, cflags_end, allow_warnings)
"""
        if text.contains(cflagsNeedle) {
            text = text.replacingOccurrences(of: cflagsNeedle, with: cflagsReplacement)
        }

        let hostLdflagsNeedle = """
    bld.SAMBA_BINARY(binname,
                     source         = '',
                     deps           = obj_target,
                     includes       = includes,
                     cflags         = cflags,
                     cflags_end     = cflags_end,
                     allow_warnings = allow_warnings,
                     group          = group,
                     use_hostcc     = use_hostcc,
                     use_global_deps= use_global_deps,
                     install_path   = None,
                     install        = install)
"""
        let hostLdflagsReplacement = """
    bld.SAMBA_BINARY(binname,
                     source         = '',
                     deps           = obj_target,
                     includes       = includes,
                     ldflags        = ['-target', 'arm64-apple-macos13.0'] if use_hostcc else [],
                     cflags         = cflags,
                     cflags_end     = cflags_end,
                     allow_warnings = allow_warnings,
                     group          = group,
                     use_hostcc     = use_hostcc,
                     use_global_deps= use_global_deps,
                     install_path   = None,
                     install        = install)
"""
        if text.contains(hostLdflagsNeedle) {
            text = text.replacingOccurrences(of: hostLdflagsNeedle, with: hostLdflagsReplacement)
        }

        text = text.replacingOccurrences(of: "HEIMDAL_ASN1('HEIMDAL_KX509_ASN1',",
                         with: "# Disabled for visionOS cross build: kx509 ASN.1 generation\n    # HEIMDAL_ASN1('HEIMDAL_KX509_ASN1',")
        text = text.replacingOccurrences(of: "\n        'lib/asn1/kx509.asn1',\n        directory='lib/asn1'\n        )\n", with: "\n")

        text = text.replacingOccurrences(of: "kdc/kx509.c", with: "")
        text = text.replacingOccurrences(of: " kx509.c", with: "")
        text = text.replacingOccurrences(of: "kx509_err.c", with: "")
        // Keep host tools self-contained: LIBREPLACE_HOSTCC drags target objects
        // into host links during cross builds and breaks tool linking.
        text = text.replacingOccurrences(of: "LIBREPLACE_HOSTCC ", with: "")
        text = text.replacingOccurrences(of: " LIBREPLACE_HOSTCC", with: "")
        text = text.replacingOccurrences(of: "deps='LIBREPLACE_HOSTCC'", with: "deps=''" )
        text = text.replacingOccurrences(of: " HEIMDAL_KX509_ASN1 ", with: " ")
        text = text.replacingOccurrences(of: " HEIMDAL_KX509_ASN1\n", with: "\n")
        text = text.replacingOccurrences(of: "HEIMDAL_KX509_ASN1 ", with: "")
        text = text.replacingOccurrences(of: "\n        HEIMDAL_KX509_ASN1\n", with: "\n")

        try text.write(toFile: file, atomically: true, encoding: .utf8)

        let cacheFile = (sourceRoot + "third_party/heimdal/lib/krb5/cache.c").path
        guard var cacheText = try? String(contentsOfFile: cacheFile, encoding: .utf8) else {
            return
        }

        cacheText = cacheText.replacingOccurrences(of:
            """
        if (enabled) {
            _krb5_debug(context, 2, "attempting to fetch a certificate using "
                        "kx509");
            ret = krb5_kx509(context, id, NULL);
            if (ret)
                _krb5_debug(context, 2, "failed to fetch a certificate");
            else
                _krb5_debug(context, 2, "fetched a certificate");
        }
""",
            with:
            """
        if (enabled) {
            _krb5_debug(context, 2, "skipping kx509 certificate fetch on visionOS build");
        }
""")

        try cacheText.write(toFile: cacheFile, atomically: true, encoding: .utf8)
    }

    private func patchWafHostToolLinking(in sourceRoot: URL) throws {
        let wafFile = (sourceRoot + "buildtools/wafsamba/wafsamba.py").path
        guard var text = try? String(contentsOfFile: wafFile, encoding: .utf8) else {
            return
        }

        text = text.replacingOccurrences(of: "        top            = True,\n        samba_subsystem= subsystem_name,",
                                         with: "        top            = True,\n        samba_use_hostcc = use_hostcc,\n        samba_subsystem= subsystem_name,")

        let hostLinkNeedle = """
        samba_install  = install,
        samba_ldflags  = pie_ldflags
        )
"""
        let hostLinkReplacement = """
        samba_install  = install,
        samba_ldflags  = pie_ldflags
        )

    if use_hostcc:
        # Host tools must not inherit target link flags from cross LDFLAGS.
        t.env.LDFLAGS = []
        t.env.LINKFLAGS = TO_LIST(bld.env.HOSTLDFLAGS) + TO_LIST(pie_ldflags)
"""
        if text.contains(hostLinkNeedle) && !text.contains("t.env.LDFLAGS = []") {
            text = text.replacingOccurrences(of: hostLinkNeedle, with: hostLinkReplacement)
        }

        try text.write(toFile: wafFile, atomically: true, encoding: .utf8)

        let replaceFile = (sourceRoot + "third_party/heimdal_build/replace.c").path
        guard var replaceText = try? String(contentsOfFile: replaceFile, encoding: .utf8) else {
            return
        }
        if !replaceText.contains("rep_closefrom") {
            replaceText += """

int rep_closefrom(int lower)
{
   int maxfd = (int)sysconf(_SC_OPEN_MAX);
   int fd;
   if (maxfd < 0) {
      maxfd = 1024;
   }
   for (fd = lower; fd < maxfd; fd++) {
      close(fd);
   }
   return 0;
}

long long int rep_strtoll(const char *str, char **endptr, int base)
{
   return strtoll(str, endptr, base);
}
"""
            try replaceText.write(toFile: replaceFile, atomically: true, encoding: .utf8)
        }
    }

    private func patchPidlStrictErrorsForCrossBuild(in sourceRoot: URL) throws {
        let clientPm = (sourceRoot + "pidl/lib/Parse/Pidl/Samba4/NDR/Client.pm").path
        if var text = try? String(contentsOfFile: clientPm, encoding: .utf8) {
            text = text.replacingOccurrences(
                of: "error($e->{ORIGINAL}, \"$fn->{NAME}: [out] argument '$e->{NAME}' $reason, skip client functions\");",
                with: "warning($e->{ORIGINAL}, \"$fn->{NAME}: [out] argument '$e->{NAME}' $reason, skip client functions\");"
            )
            text = text.replacingOccurrences(
                of: "fatal($e->{ORIGINAL}, \"[out] argument is not a pointer or array\");",
                with: "warning($e->{ORIGINAL}, \"[out] argument is not a pointer or array\");"
            )
            try text.write(toFile: clientPm, atomically: true, encoding: .utf8)
        }

        let pythonPm = (sourceRoot + "pidl/lib/Parse/Pidl/Samba4/Python.pm").path
        if var text = try? String(contentsOfFile: pythonPm, encoding: .utf8) {
            text = text.replacingOccurrences(
                of: "error($location, \"Unable to determine origin of type `\" . mapTypeName($ctype) . \"'\");",
                with: "warning($location, \"Unable to determine origin of type `\" . mapTypeName($ctype) . \"'\");"
            )
            try text.write(toFile: pythonPm, atomically: true, encoding: .utf8)
        }
    }

    private func patchLocalNpEnvironDeclaration(in sourceRoot: URL) throws {
        let filePath = (sourceRoot + "source3/rpc_client/local_np.c").path
        if var text = try? String(contentsOfFile: filePath, encoding: .utf8) {
            if !text.contains("#include <dlfcn.h>") {
                text = text.replacingOccurrences(
                    of: "#include <spawn.h>",
                    with: "#include <spawn.h>\n#include <dlfcn.h>"
                )
            }
            // Add extern declaration for environ before the function that uses it.
            // The file already has unistd.h via includes.h, but environ isn't always
            // automatically declared on all platforms (especially visionOS).
            let insertPoint = "become_root();"
            if let range = text.range(of: insertPoint) {
                let declaration = "extern char **environ;\n        "
                text.insert(contentsOf: declaration, at: range.lowerBound)
            }

            text = text.replacingOccurrences(
                of: "\tret = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);",
                with: """
	{
		typedef int (*posix_spawn_fn_t)(pid_t * __restrict, const char * __restrict,
			const posix_spawn_file_actions_t * __restrict,
			const posix_spawnattr_t * __restrict,
			char *const argv[__restrict],
			char *const envp[__restrict]);
		posix_spawn_fn_t posix_spawn_fn = (posix_spawn_fn_t)dlsym(RTLD_DEFAULT, "posix_spawn");
		ret = posix_spawn_fn ? posix_spawn_fn(&pid, argv[0], NULL, NULL, argv, environ) : ENOSYS;
	}
"""
            )

            try text.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }

    private func patchFcntlLockForkUnavailable(in sourceRoot: URL) throws {
        // Patch tests/fcntl_lock.c which calls fork() - unavailable at compile time on tvOS/watchOS.
        // The test binary needs to compile (it then uses --cross-answers to supply the answer at runtime).
        // Use dlsym to avoid compile-time availability errors.
        let filePath = (sourceRoot + "tests/fcntl_lock.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }

        let oldFork = "if (!(pid=fork())) {"
        guard text.contains(oldFork) else { return }

        let newFork = """
{
            typedef pid_t (*fork_fn_t)(void);
            fork_fn_t fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
            pid = fork_fn ? fork_fn() : (pid_t)-1;
        }
        if (!pid) {
"""
        // Insert dlfcn.h include after the last existing #include
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include <errno.h>",
                with: "#include <errno.h>\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(of: oldFork, with: newFork)
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchSimpleExecForkUnavailable(in sourceRoot: URL) throws {
        // third_party/heimdal/lib/roken/simple_exec.c uses fork()/execv/execvp/execve
        // which are compile-time prohibited on tvOS/watchOS. Stub them out by setting
        // pid = -1 (always "fork failed") and removing the unreachable exec calls.
        // This mirrors the intent of 05-no_fork_and_exec.patch which targets the
        // old source4/heimdal path that no longer exists in Samba 4.24.x.
        let filePath = (sourceRoot + "third_party/heimdal/lib/roken/simple_exec.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }

        // Stub pipe_execv: replace `pid = fork();` (assignment, not declaration)
        text = text.replacingOccurrences(
            of: "    pid = fork();\n    switch(pid) {",
            with: "    pid = -1;\n    switch(pid) {"
        )
        // Remove unreachable execv call in pipe_execv case 0 branch
        text = text.replacingOccurrences(
            of: "\n\n\texecv(file, argv);\n\texit(",
            with: "\n\n\texit("
        )

        // Stub simple_execvp_timed: replace fork() + remove execvp
        text = text.replacingOccurrences(
            of: "    pid_t pid = fork();\n    switch(pid){\n    case -1:\n\treturn SE_E_FORKFAILED;\n    case 0:\n\texecvp(file, args);\n\texit(",
            with: "    pid_t pid = -1;\n    switch(pid){\n    case -1:\n\treturn SE_E_FORKFAILED;\n    case 0:\n\texit("
        )

        // Stub simple_execve_timed: replace fork() + remove execve
        text = text.replacingOccurrences(
            of: "    pid_t pid = fork();\n    switch(pid){\n    case -1:\n\treturn SE_E_FORKFAILED;\n    case 0:\n\texecve(file, args, envp);\n\texit(",
            with: "    pid_t pid = -1;\n    switch(pid){\n    case -1:\n\treturn SE_E_FORKFAILED;\n    case 0:\n\texit("
        )

        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchTForkForkUnavailable(in sourceRoot: URL) throws {
        // lib/util/tfork.c has two fork() calls — unavailable at compile time on tvOS/watchOS.
        // Replace both with dlsym-based calls. tfork functionality won't work at runtime on tvOS
        // but the symbol must compile for libsmbclient to link.
        let filePath = (sourceRoot + "lib/util/tfork.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("\tpid = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"replace.h\"",
                with: "#include \"replace.h\"\n#include <dlfcn.h>"
            )
        }
        // Replace all occurrences of `pid = fork();` (both caller and waiter)
        text = text.replacingOccurrences(
            of: "\tpid = fork();\n\tif (pid == -1) {",
            with: """
\t{
\t\ttypedef pid_t (*fork_fn_t)(void);
\t\tfork_fn_t fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
\t\tpid = fork_fn ? fork_fn() : (pid_t)-1;
\t}
\tif (pid == -1) {
"""
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchSmbrunForkExecUnavailable(in sourceRoot: URL) throws {
        // source3/lib/smbrun.c: fork(), execle(), execl() — unavailable on tvOS/watchOS.
        // Two fork() call sites and two exec call sites. Replace all with dlsym-based calls.
        let filePath = (sourceRoot + "source3/lib/smbrun.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("(pid=fork()) < 0") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"includes.h\"",
                with: "#include \"includes.h\"\n#include <dlfcn.h>"
            )
        }
        // Stub both fork() calls (same pattern, replacingOccurrences replaces all)
        // Use GCC statement expression ({...}) which Clang supports.
        text = text.replacingOccurrences(
            of: "(pid=fork()) < 0",
            with: "({typedef pid_t (*fork_fn_t)(void); fork_fn_t ffn=(fork_fn_t)dlsym(RTLD_DEFAULT,\"fork\"); pid=ffn?ffn():(pid_t)-1;}) < 0"
        )
        // Stub execle
        text = text.replacingOccurrences(
            of: "\t\t\texecle(\"/bin/sh\",\"sh\",\"-c\",\n\t\t\t\tnewcmd ? (const char *)newcmd : cmd, NULL,\n\t\t\t\tenv);",
            with: "\t\t\t{typedef int(*execle_fn_t)(const char*,...); execle_fn_t fn=(execle_fn_t)dlsym(RTLD_DEFAULT,\"execle\"); if(fn)fn(\"/bin/sh\",\"sh\",\"-c\",newcmd?(const char*)newcmd:cmd,NULL,env);}"
        )
        // Stub execl in child branch
        text = text.replacingOccurrences(
            of: "\t\t\texecl(\"/bin/sh\",\"sh\",\"-c\",\n\t\t\t\tnewcmd ? (const char *)newcmd : cmd, NULL);",
            with: "\t\t\t{typedef int(*execl_fn_t)(const char*,...); execl_fn_t fn=(execl_fn_t)dlsym(RTLD_DEFAULT,\"execl\"); if(fn)fn(\"/bin/sh\",\"sh\",\"-c\",newcmd?(const char*)newcmd:cmd,NULL);}"
        )
        // Stub execl at bottom of function
        text = text.replacingOccurrences(
            of: "\texecl(\"/bin/sh\", \"sh\", \"-c\", cmd, NULL);",
            with: "\t{typedef int(*execl_fn_t)(const char*,...); execl_fn_t fn=(execl_fn_t)dlsym(RTLD_DEFAULT,\"execl\"); if(fn)fn(\"/bin/sh\",\"sh\",\"-c\",cmd,NULL);}"
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchBackgroundForkUnavailable(in sourceRoot: URL) throws {
        // source3/lib/background.c uses fork() — unavailable on tvOS/watchOS.
        let filePath = (sourceRoot + "source3/lib/background.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("\tres = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"includes.h\"",
                with: "#include \"includes.h\"\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(
            of: "\tres = fork();",
            with: "\t{typedef pid_t (*fork_fn_t)(void); fork_fn_t ffn=(fork_fn_t)dlsym(RTLD_DEFAULT,\"fork\"); res=ffn?ffn():(pid_t)-1;}"
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchTdbValidateForkUnavailable(in sourceRoot: URL) throws {
        // source3/lib/tdb_validate.c uses fork() — unavailable on tvOS/watchOS.
        let filePath = (sourceRoot + "source3/lib/tdb_validate.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("\tchild_pid = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"includes.h\"",
                with: "#include \"includes.h\"\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(
            of: "\tchild_pid = fork();",
            with: "\t{typedef pid_t (*fork_fn_t)(void); fork_fn_t ffn=(fork_fn_t)dlsym(RTLD_DEFAULT,\"fork\"); child_pid=ffn?ffn():(pid_t)-1;}"
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchDnsExForkUnavailable(in sourceRoot: URL) throws {
        // source4/libcli/resolve/dns_ex.c uses fork() — unavailable on tvOS/watchOS.
        let filePath = (sourceRoot + "source4/libcli/resolve/dns_ex.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("\tstate->child = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"includes.h\"",
                with: "#include \"includes.h\"\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(
            of: "\tstate->child = fork();",
            with: "\t{typedef pid_t (*fork_fn_t)(void); fork_fn_t ffn=(fork_fn_t)dlsym(RTLD_DEFAULT,\"fork\"); state->child=ffn?ffn():(pid_t)-1;}"
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchRandTimerForkUnavailable(in sourceRoot: URL) throws {
        // third_party/heimdal/lib/hcrypto/rand-timer.c uses fork() in the #else branch
        // (when HAVE_SETITIMER is not defined) — unavailable at compile time on tvOS/watchOS.
        // Replace with dlsym-based call.
        let filePath = (sourceRoot + "third_party/heimdal/lib/hcrypto/rand-timer.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("    pid = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include <roken.h>",
                with: "#include <roken.h>\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(
            of: "    pid = fork();\n    if(pid == -1){",
            with: """
    {
        typedef pid_t (*fork_fn_t)(void);
        fork_fn_t fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
        pid = fork_fn ? fork_fn() : (pid_t)-1;
    }
    if(pid == -1){
"""
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }


    private func patchUtilRuncmdExecvpUnavailable(in sourceRoot: URL) throws {
        // lib/util/util_runcmd.c uses execvp() — unavailable at compile time on tvOS/watchOS.
        // Replace with dlsym-based call. This runs in the child after tfork; on tvOS the
        // UTIL_RUNCMD paths are never invoked but must compile.
        let filePath = (sourceRoot + "lib/util/util_runcmd.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("(void)execvp(state->arg0, argv);") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"replace.h\"",
                with: "#include \"replace.h\"\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(
            of: "\t(void)execvp(state->arg0, argv);",
            with: """
\t{
\t\ttypedef int (*execvp_fn_t)(const char *, char * const *);
\t\texecvp_fn_t execvp_fn = (execvp_fn_t)dlsym(RTLD_DEFAULT, "execvp");
\t\tif (execvp_fn) { (void)execvp_fn(state->arg0, argv); }
\t}
"""
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchSysPOpenForkExecUnavailable(in sourceRoot: URL) throws {
        // Replace with dlsym-based calls so it compiles; popen functionality won't work at runtime on tvOS
        // but libsmbclient itself doesn't invoke popen paths in normal SMB operations.
        let filePath = (sourceRoot + "lib/util/sys_popen.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("entry->child_pid = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"replace.h\"",
                with: "#include \"replace.h\"\n#include <dlfcn.h>"
            )
        }
        // Stub fork()
        text = text.replacingOccurrences(
            of: "entry->child_pid = fork();",
            with: """
{
                    typedef pid_t (*fork_fn_t)(void);
                    fork_fn_t fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
                    entry->child_pid = fork_fn ? fork_fn() : (pid_t)-1;
                }
"""
        )
        // Stub execv: replace direct call with dlsym-based call
        text = text.replacingOccurrences(
            of: "ret = execv(argl[0], argl);",
            with: """
{
                    typedef int (*execv_fn_t)(const char *, char * const *);
                    execv_fn_t execv_fn = (execv_fn_t)dlsym(RTLD_DEFAULT, "execv");
                    ret = execv_fn ? execv_fn(argl[0], argl) : -1;
                }
"""
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchBecomeDaemonForkUnavailable(in sourceRoot: URL) throws {
        // lib/util/become_daemon.c uses fork() which is unavailable at compile time on tvOS/watchOS.
        // Replace the fork() call with a dlsym-based call so it compiles; at runtime on tvOS
        // become_daemon() should never be invoked, but it still needs to link.
        let filePath = (sourceRoot + "lib/util/become_daemon.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("newpid = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"replace.h\"",
                with: "#include \"replace.h\"\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(
            of: "newpid = fork();",
            with: """
{
                    typedef pid_t (*fork_fn_t)(void);
                    fork_fn_t fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
                    newpid = fork_fn ? fork_fn() : (pid_t)-1;
                }
"""
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchUtilSambaStartDebuggerForkUnavailable(in sourceRoot: URL) throws {
        // lib/util/util.c: samba_start_debugger() uses fork() — unavailable on tvOS/watchOS.
        // Stub with dlsym. This function is only called for debugger attach, never in SMB client paths.
        let filePath = (sourceRoot + "lib/util/util.c").path
        guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        guard text.contains("pid = fork();") else { return }
        if !text.contains("#include <dlfcn.h>") {
            text = text.replacingOccurrences(
                of: "#include \"replace.h\"",
                with: "#include \"replace.h\"\n#include <dlfcn.h>"
            )
        }
        text = text.replacingOccurrences(
            of: "\tpid = fork();\n\tSMB_ASSERT(pid >= 0);",
            with: """
\t{
\t\ttypedef pid_t (*fork_fn_t)(void);
\t\tfork_fn_t fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
\t\tpid = fork_fn ? fork_fn() : (pid_t)-1;
\t}
\tSMB_ASSERT(pid >= 0);
"""
        )
        try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    private func patchFaultSystemCallUnavailable(in sourceRoot: URL) throws {
        // Patch multiple files that use system() which is unavailable on iOS/tvOS/watchOS
        let filesToPatch = [
            "lib/util/fault.c",           // Primary fault handling
            "source3/lib/util.c"          // Utility functions
        ]

        for relativePath in filesToPatch {
            let filePath = (sourceRoot + relativePath).path
            guard var text = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }

            // The system() call is unavailable on iOS, tvOS, and watchOS.
            // Use dlsym to indirectly call system() - this avoids compile-time availability checking.
            // On iOS/tvOS where system() doesn't exist, dlsym will return NULL and we default to -1.
            
            let pattern = "result = system(cmd"
            guard text.contains(pattern) else { continue }

            // Replace both "result = system(cmd);" and "result = system(cmdstring);" patterns
            text = text.replacingOccurrences(
                of: "result = system(cmdstring);",
                with: """
{
                        typedef int (*system_fn_t)(const char *);
                        system_fn_t sys_fn = (system_fn_t)dlsym(RTLD_DEFAULT, "system");
                        result = (sys_fn != NULL) ? sys_fn(cmdstring) : -1;
                    }
"""
            )
            
            text = text.replacingOccurrences(
                of: "result = system(cmd);",
                with: """
{
                        typedef int (*system_fn_t)(const char *);
                        system_fn_t sys_fn = (system_fn_t)dlsym(RTLD_DEFAULT, "system");
                        result = (sys_fn != NULL) ? sys_fn(cmd) : -1;
                    }
"""
            )

            try text.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }

    private func patchSystemAsn1IdentifierCompatibility(in sourceRoot: URL) throws {
        let files = [
            (sourceRoot + "third_party/heimdal/lib/asn1/rfc2459.asn1").path,
            (sourceRoot + "third_party/heimdal/lib/asn1/pkcs10.asn1").path,
        ]

        for file in files {
            guard var text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }

            // Homebrew/system Heimdal asn1 compiler rejects type identifiers that
            // begin with '_'. Keep semantics intact by renaming only identifiers.
            text = text.replacingOccurrences(of: "_OTHER-NAME", with: "OTHER-NAME")
            text = text.replacingOccurrences(of: "_ATTRIBUTE", with: "ATTRIBUTE")
            text = text.replacingOccurrences(of: "_EXTENSION", with: "EXTENSION")
            text = text.replacingOccurrences(of: "_POLICYQUALIFIERINFO", with: "POLICYQUALIFIERINFO")

            try text.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    override func wafPath() -> String {
        "buildtools/bin/waf"
    }

    override func flagsDependencelibrarys() -> [Library] {
        // Static gnutls requires downstream crypto libs to appear later in
        // link order so unresolved GMP symbols can be satisfied.
        [.gnutls, .nettle, .gmp]
    }

    override func cFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var cFlags = super.cFlags(platform: platform, arch: arch)
        cFlags.append("-Wno-error=implicit-function-declaration")
        cFlags.append("-Wno-error=unused-command-line-argument")
        return cFlags
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        env["PATH"]? += (":" + (URL.currentDirectory + "../Plugins/BuildFFmpeg/\(library.rawValue)/bin").path + ":" + (directoryURL + "buildtools/bin").path)
        // Samba waf currently relies on distutils, which is removed in Python 3.12+.
        // Pin to macOS system Python to keep waf configure working.
        env["PYTHON"] = "/usr/bin/python3"
        if let path = env["PATH"] {
            // Prefer modern parser tools from Homebrew over older macOS system versions.
            // Include Heimdal libexec so asn1_compile is discoverable by waf find_program.
            env["PATH"] = "/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/usr/bin:/opt/homebrew/opt/heimdal/bin:/opt/homebrew/opt/heimdal/libexec/heimdal:" + path
        }
        env["BISON"] = "/opt/homebrew/opt/bison/bin/bison"
        env["YACC"] = "/opt/homebrew/opt/bison/bin/bison -y"
        env["LEX"] = "/opt/homebrew/opt/flex/bin/flex"
        // Darwin libc does not provide secure_getenv(). Heimdal roken expects it
        // on some code paths, so map to getenv() for cross builds.
        let secureGetenvDefine = " -Dsecure_getenv=getenv"
        env["CFLAGS"] = (env["CFLAGS"] ?? "") + secureGetenvDefine
        env["CXXFLAGS"] = (env["CXXFLAGS"] ?? "") + secureGetenvDefine
        env["HOSTCFLAGS"] = (env["HOSTCFLAGS"] ?? "") + secureGetenvDefine
        // Ensure waf hostcc utilities (e.g. compile_et/asn1_compile) are built
        // for the build host, not the cross target.
        env["HOSTCC"] = "/usr/bin/clang"
        env["HOSTCXX"] = "/usr/bin/clang++"
        env["HOSTCFLAGS"] = (env["HOSTCFLAGS"] ?? "") + " -O2"
        env["HOSTCXXFLAGS"] = "-O2"
        env["HOSTLDFLAGS"] = ""
        env["CC_FOR_BUILD"] = "/usr/bin/clang"
        env["CXX_FOR_BUILD"] = "/usr/bin/clang++"
        // Ensure host tools (asn1_compile/compile_et) are built for macOS even
        // during cross builds, otherwise waf may emit xros binaries that cannot run.
        let hostTarget = "-target arm64-apple-macos13.0"
        env["HOSTCFLAGS"] = "-O2 \(hostTarget)"
        env["HOSTCXXFLAGS"] = "-O2 \(hostTarget)"
        env["HOSTLDFLAGS"] = hostTarget
        env["CC_FOR_BUILD"] = "/usr/bin/clang \(hostTarget)"
        env["CXX_FOR_BUILD"] = "/usr/bin/clang++ \(hostTarget)"
        env["PYTHONHASHSEED"] = "1"
        env["WAF_MAKE"] = "1"
        return env
    }

    override func wafBuildArg() -> [String] {
        ["--targets=smbclient"]
    }

    override func wafInstallArg() -> [String] {
        ["--targets=smbclient"]
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        let fm = FileManager.default
        let safeRoot = URL(fileURLWithPath: "/tmp/ffmpegkit-nospace", isDirectory: true)
        try? fm.createDirectory(at: safeRoot, withIntermediateDirectories: true, attributes: nil)

        var environ = environment(platform: platform, arch: arch)

        // Replace .Script path references in env vars with a no-space symlink.
        let spacedScriptDir = URL.currentDirectory.path
        let safeScriptLink = (safeRoot + "Script").path
        if fm.fileExists(atPath: safeScriptLink) {
            if let target = try? fm.destinationOfSymbolicLink(atPath: safeScriptLink),
               target != spacedScriptDir {
                try? fm.removeItem(atPath: safeScriptLink)
            }
        }
        if !fm.fileExists(atPath: safeScriptLink) {
            try fm.createSymbolicLink(atPath: safeScriptLink, withDestinationPath: spacedScriptDir)
        }
        for (key, value) in environ {
            environ[key] = value.replacingOccurrences(of: spacedScriptDir, with: safeScriptLink)
        }

        // Use a real no-space source copy (not symlink). Some waf/samba helper scripts
        // resolve symlinks and then shell out with unquoted absolute paths.
        let safeSource = safeRoot + "\(library.rawValue)-\(library.version)-\(platform.rawValue)-\(arch.rawValue)"
        if fm.fileExists(atPath: safeSource.path) {
            // Some prior runs leave partially populated trees that fail rsync --delete
            // with "unlinkat: Directory not empty". Force-clean first.
            try? Utility.launch(path: "/bin/rm",
                                arguments: ["-rf", safeSource.path],
                                currentDirectoryURL: safeRoot,
                                environment: environ)
        }
        try? fm.removeItem(at: safeSource)
        try fm.createDirectory(at: safeSource, withIntermediateDirectories: true, attributes: nil)
        try Utility.launch(path: "/usr/bin/rsync",
                           arguments: ["-a", "\(directoryURL.path)/", "\(safeSource.path)/"],
                           currentDirectoryURL: directoryURL,
                           environment: environ)

        try patchEmbeddedHeimdalConfig(in: safeSource)

        // Write asn1_compile wrapper for all platforms: Homebrew system asn1_compile
        // produces .x/.hx files but Samba's waf expects .c/.h; the wrapper renames them.
        try writeAsn1WrapperScript(in: safeSource)
        // Ensure our wrapper is preferred over system binaries discovered via PATH.
        if let path = environ["PATH"] {
            environ["PATH"] = "\(safeSource.path):" + path
        }
        // rfc2459/pkcs10/krb5 are routed to the bundled legacy compiler via the wrapper,
        // which has stricter syntax requirements. Apply compatibility patches for all platforms.
        try patchRfc2459ForLegacyAsn1(in: safeSource)
        try patchPkcs10ForLegacyAsn1(in: safeSource)
        try patchKrb5ForLegacyAsn1(in: safeSource)

        // hx509 flattened-rfc2459 patches: the bundled asn1_compile (used for rfc2459/pkcs10/krb5)
        // does not generate _ioschoice wrappers. Apply compatibility patches for all platforms.
        try patchHx509ForFlattenedRfc2459(in: safeSource)
        try patchHx509PrivateKeyPrototype(in: safeSource)
        try patchHx509CaForFlattenedRfc2459(in: safeSource)
        try patchHx509ReqForFlattenedRfc2459(in: safeSource)
        try patchHx509PrintForFlattenedRfc2459(in: safeSource)
        // System asn1_compile generates CompositePrincipal from krb5.asn1; patch all platforms.
        try patchKrb5PrincipalForCompositeNameattrs(in: safeSource)
        try patchHeimdalGssapiForCompositePrincipal(in: safeSource)
        // PIDL treats unresolvable server-side struct types as errors; demote to warnings.
        try patchPidlStrictErrorsForCrossBuild(in: safeSource)
        // Declare environ extern for posix_spawn in local_np.c (all platforms need this).
        try patchLocalNpEnvironDeclaration(in: safeSource)
        // Wrap system() call in fault.c since it's unavailable on iOS/tvOS.
        try patchFaultSystemCallUnavailable(in: safeSource)
        // Wrap fork() in tests/fcntl_lock.c since it's compile-time prohibited on tvOS/watchOS.
        try patchFcntlLockForkUnavailable(in: safeSource)
        // Stub fork()/exec in third_party/heimdal/lib/roken/simple_exec.c (ROKEN_HOSTCC target).
        try patchSimpleExecForkUnavailable(in: safeSource)
        // Stub fork() in lib/util/become_daemon.c (samba-util-core task) — unavailable on tvOS/watchOS.
        try patchBecomeDaemonForkUnavailable(in: safeSource)
        // Stub fork()/execv in lib/util/sys_popen.c (samba-util-core task) — unavailable on tvOS/watchOS.
        try patchSysPOpenForkExecUnavailable(in: safeSource)
        // Stub fork() in lib/util/util.c samba_start_debugger() — unavailable on tvOS/watchOS.
        try patchUtilSambaStartDebuggerForkUnavailable(in: safeSource)
        // Stub fork() in lib/util/tfork.c (samba-util.objlist task) — unavailable on tvOS/watchOS.
        try patchTForkForkUnavailable(in: safeSource)
        // Stub execvp() in lib/util/util_runcmd.c (UTIL_RUNCMD task) — unavailable on tvOS/watchOS.
        try patchUtilRuncmdExecvpUnavailable(in: safeSource)
        // Stub fork() in third_party/heimdal/lib/hcrypto/rand-timer.c — unavailable on tvOS/watchOS.
        try patchRandTimerForkUnavailable(in: safeSource)
        // Stub fork()/execle()/execl() in source3/lib/smbrun.c (samba3core task) — unavailable on tvOS/watchOS.
        try patchSmbrunForkExecUnavailable(in: safeSource)
        // Stub fork() in source3/lib/background.c (samba3core task) — unavailable on tvOS/watchOS.
        try patchBackgroundForkUnavailable(in: safeSource)
        // Stub fork() in source3/lib/tdb_validate.c (TDB_VALIDATE task) — unavailable on tvOS/watchOS.
        try patchTdbValidateForkUnavailable(in: safeSource)
        // Stub fork() in source4/libcli/resolve/dns_ex.c (LP_RESOLVE task) — unavailable on tvOS/watchOS.
        try patchDnsExForkUnavailable(in: safeSource)

        if platform.rawValue == "xros" || platform.rawValue == "xrsimulator" {
            try patchHeimdalAsn1SourcesForDisabledKx509(in: safeSource)
            try patchVisionOSIncompatibilities(in: safeSource)
            try patchHeimdalKx509ForVisionOS(in: safeSource)
            try patchWafHostToolLinking(in: safeSource)
        }

        let safePrefix = safeRoot + "install-\(library.rawValue)-\(platform.rawValue)-\(arch.rawValue)"
        try? fm.removeItem(at: safePrefix)
        try fm.createDirectory(at: safePrefix, withIntermediateDirectories: true, attributes: nil)

        let waf = (safeSource + wafPath()).path
        var configureArgs = arguments(platform: platform, arch: arch).filter { !$0.hasPrefix("--prefix=") }
        configureArgs.append("--prefix=\(safePrefix.path)")

        try writeCrossAnswers(in: safeSource, arch: arch)

        try Utility.launch(path: waf, arguments: ["configure"] + configureArgs, currentDirectoryURL: safeSource, environment: environ)
        try Utility.launch(path: waf, arguments: wafBuildArg(), currentDirectoryURL: safeSource, environment: environ)
        try Utility.launch(path: waf, arguments: ["install"] + wafInstallArg(), currentDirectoryURL: safeSource, environment: environ)

        // Copy from no-space install prefix to real thin dir.
        let realPrefix = thinDir(platform: platform, arch: arch)
        try? fm.removeItem(at: realPrefix)
        try? fm.createDirectory(at: realPrefix.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try fm.copyItem(at: safePrefix, to: realPrefix)

        // Samba build places static libs under bin/default; copy it explicitly.
        let staticLib = safeSource + "bin/default/source3/libsmb/libsmbclient.a"
        let staticLibDest = realPrefix + "lib/libsmbclient.a"
        let dylib = safeSource + "bin/default/source3/libsmb/libsmbclient.dylib"
        let dylibDest = realPrefix + "lib/libsmbclient.dylib"

        if !fm.fileExists(atPath: staticLib.path) {
            let libsmbDir = safeSource + "bin/default/source3/libsmb"
            let objectFiles = (try? fm.contentsOfDirectory(atPath: libsmbDir.path))?
                .filter { $0.hasSuffix(".o") }
                .sorted()
                .map { (libsmbDir + $0).path } ?? []

            if !objectFiles.isEmpty {
                try Utility.launch(path: "/usr/bin/libtool",
                                   arguments: ["-static", "-o", staticLib.path] + objectFiles,
                                   currentDirectoryURL: safeSource,
                                   environment: environ)
            }
        }

        // Collect .o files from the waf build tree and merge into libsmbclient.a so
        // the xcframework is self-contained (includes tevent, talloc, samba-util, etc.).
        // For cross-target builds, skip host-tool Heimdal objects (.3/.76/.102) that
        // are compiled for macOS and must not be included in iOS/tvOS/visionOS archives.
        let binDefault = safeSource + "bin/default"
        let isCrossTarget = (platform != .macos && platform != .maccatalyst)
        var allObjectFiles: [String] = []
        if let enumerator = fm.enumerator(at: binDefault, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                if path.hasSuffix(".o") {
                    if path.contains("/third_party/heimdal/") || path.contains("/third_party/heimdal_build/") {
                        if isCrossTarget {
                            if path.hasSuffix(".3.o") || path.hasSuffix(".76.o") || path.hasSuffix(".102.o") {
                                continue
                            }
                        }
                    }
                    allObjectFiles.append(path)
                }
            }
        }
        allObjectFiles.sort()
        if !allObjectFiles.isEmpty {
            let mergedLib = safeSource + "bin/default/source3/libsmb/libsmbclient-merged.a"
            try Utility.launch(path: "/usr/bin/libtool",
                               arguments: ["-static", "-o", mergedLib.path] + allObjectFiles,
                               currentDirectoryURL: safeSource,
                               environment: environ)
            try? fm.removeItem(at: staticLib)
            try fm.moveItem(at: mergedLib, to: staticLib)
        }

        try? fm.removeItem(at: staticLibDest)
        try fm.copyItem(at: staticLib, to: staticLibDest)

        if fm.fileExists(atPath: dylib.path) {
            try? fm.removeItem(at: dylibDest)
            try fm.copyItem(at: dylib, to: dylibDest)
        }
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        var arg =
            [
                "--without-cluster-support",
                "--disable-rpath",
                "--without-ldap",
                "--without-pam",
                "--enable-fhs",
                "--without-winbind",
                "--without-ads",
                "--disable-avahi",
                "--disable-cups",
                "--without-gettext",
                "--without-ad-dc",
                "--without-acl-support",
                "--without-utmp",
                "--disable-iprint",
                "--nopyc",
                "--nopyo",
                "--disable-python",
                "--disable-symbol-versions",
                "--without-json",
                "--without-libarchive",
                "--without-regedit",
                "--without-lttng",
                "--without-gpgme",
                "--disable-cephfs",
                "--disable-glusterfs",
                "--without-syslog",
                "--without-quotas",
                "--bundled-libraries=ALL",
                "--with-static-modules=!vfs_snapper,ALL",
                "--host=\(platform.host(arch: arch))",
                "--prefix=\(thinDir(platform: platform, arch: arch).path)",
            ]
        // Spotlight support is server-side (mdssvc). Keep it enabled generally,
        // but disable it on visionOS targets for the client-only libsmbclient build.
        if platform == .xros || platform == .xrsimulator {
            arg.append("--disable-spotlight")
            // Ensure host utilities (asn1_compile/compile_et) are built for macOS,
            // not the cross target, so waf can execute them during codegen.
            arg.append("--hostcc=/usr/bin/clang")
        }
        arg.append("--cross-compile")
        arg.append("--cross-answers=cross-answers.txt")
        return arg
    }

}

class BuildReadline: BaseBuild {
    init() {
        super.init(library: .readline)
    }

    // readline 只是在编译的时候需要用到。外面不需要用到
    override func frameworks() throws -> [String] {
        []
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        try autoToolsBuildWithNoSpacePaths(platform: platform, arch: arch, buildURL: buildURL)
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "--enable-static",
            "--disable-shared",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
        ]
    }
}

class BuildGmp: BaseBuild {
    init() {
        super.init(library: .gmp)
        if Utility.shell("which makeinfo") == nil {
            Utility.shell("brew install texinfo")
        }
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        try autoToolsBuildWithNoSpacePaths(platform: platform, arch: arch, buildURL: buildURL)
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "--disable-maintainer-mode",
            "--disable-assembly",
            "--with-pic",
            "--enable-static",
            "--disable-shared",
            "--disable-fast-install",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
        ]
    }
}

class BuildNettle: BaseBuild {
    init() {
        if Utility.shell("which autoconf") == nil {
            Utility.shell("brew install autoconf")
        }
        super.init(library: .nettle)
    }

    override func flagsDependencelibrarys() -> [Library] {
        [.gmp]
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        try autoToolsBuildWithNoSpacePaths(platform: platform, arch: arch, buildURL: buildURL)
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "--disable-assembler",
            "--disable-openssl",
            "--disable-gcov",
            "--disable-documentation",
            "--enable-pic",
            "--enable-static",
            "--disable-shared",
            "--disable-dependency-tracking",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
//                arch == .arm64 || arch == .arm64e ? "--enable-arm-neon" : "--enable-x86-aesni",
        ]
    }

    override func frameworks() throws -> [String] {
        [library.rawValue, "hogweed"]
    }
}

class BuildGnutls: BaseBuild {
    init() {
        if Utility.shell("which automake") == nil {
            Utility.shell("brew install automake")
        }
        if Utility.shell("which gtkdocize") == nil {
            Utility.shell("brew install gtk-doc")
        }
        if Utility.shell("which wget") == nil {
            Utility.shell("brew install wget")
        }
        if Utility.shell("brew list bison") == nil {
            Utility.shell("brew install bison")
        }
        if Utility.shell("which glibtoolize") == nil {
            Utility.shell("brew install libtool")
        }
        if Utility.shell("which asn1Parser") == nil {
            Utility.shell("brew install libtasn1")
        }
        super.init(library: .gnutls)
        // Fix autopoint compatibility with newer gettext: remove duplicate
        // AM_GNU_GETTEXT_REQUIRE_VERSION that conflicts with AM_GNU_GETTEXT_VERSION.
        let configureAC = directoryURL + "configure.ac"
        if let data = FileManager.default.contents(atPath: configureAC.path), var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(
                of: "AM_GNU_GETTEXT_VERSION([0.19])\nm4_ifdef([AM_GNU_GETTEXT_REQUIRE_VERSION],[\nAM_GNU_GETTEXT_REQUIRE_VERSION([0.19])\n])",
                with: "AM_GNU_GETTEXT_VERSION([0.19])"
            )
            try? str.write(toFile: configureAC.path, atomically: true, encoding: .utf8)
        }
    }

    override func flagsDependencelibrarys() -> [Library] {
        [.gmp, .nettle]
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        // 需要bison的版本大于2.4,系统自带的/usr/bin/bison是 2.3
        env["PATH"] = "/usr/local/opt/bison/bin:/opt/homebrew/opt/bison/bin:" + (env["PATH"] ?? "")
        return env
    }

    override func build(platform: PlatformType, arch: ArchType, buildURL: URL) throws {
        try autoToolsBuildWithNoSpacePaths(platform: platform, arch: arch, buildURL: buildURL) {
            // Patch the generated aarch64 Makefile to silence a broken CCASFLAGS line.
            let path = self.directoryURL + "lib/accelerated/aarch64/Makefile.in"
            if let data = FileManager.default.contents(atPath: path.path),
               var str = String(data: data, encoding: .utf8) {
                str = str.replacingOccurrences(of: "AM_CCASFLAGS =", with: "#AM_CCASFLAGS=")
                try! str.write(toFile: path.path, atomically: true, encoding: .utf8)
            }
        }
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "--with-included-libtasn1",
            "--with-included-unistring",
            "--without-brotli",
            "--without-idn",
            "--without-p11-kit",
            "--without-zlib",
            "--without-zstd",
            "--enable-hardware-acceleration",
            "--disable-openssl-compatibility",
            "--disable-code-coverage",
            "--disable-doc",
            "--disable-maintainer-mode",
            "--disable-manpages",
            "--disable-nls",
            "--disable-rpath",
//                "--disable-tests",
            "--disable-tools",
            "--disable-full-test-suite",
            "--with-pic",
            "--enable-static",
            "--disable-shared",
            "--disable-fast-install",
            "--disable-dependency-tracking",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
        ]
    }
}
