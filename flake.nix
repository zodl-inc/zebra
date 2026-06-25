{
  description = "zebrad — reproducible static-musl builds (amd64 + arm64)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane/v0.20.3";
    rust-overlay = { url = "github:oxalica/rust-overlay"; inputs.nixpkgs.follows = "nixpkgs"; };
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, crane, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ (import rust-overlay) ]; };
        muslTarget =
          if system == "aarch64-linux" then "aarch64-unknown-linux-musl"
          else "x86_64-unknown-linux-musl";
        # cargo reads the per-target env var named after the UPPERCASED triple
        # with -/. → _ (e.g. CC_x86_64_unknown_linux_musl). Derive it so BOTH
        # arches get the musl-clang toolchain.
        targetEnvSuffix =
          builtins.replaceStrings [ "-" "." ] [ "_" "_" ] muslTarget;
        # Match docker/rust-toolchain.toml (channel 1.91.0).
        rustToolchain = pkgs.rust-bin.stable."1.91.0".default.override {
          targets = [ muslTarget ];
        };
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
        # crane's cleanCargoSource keeps only Rust/cargo files, but zebra-chain
        # embeds data via include_str! (genesis blocks, checkpoint lists, *.txt).
        # Keep those too, or the build fails with "couldn't read ...txt".
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          name = "source";
          # zebra embeds many non-Rust data files via include_str!/include_bytes!
          # that crane's cleanCargoSource drops: genesis blocks + checkpoint
          # lists (.txt), the proto tree (zebra-rpc build.rs), and cryptographic
          # parameters like the Groth16 verifying keys (.vk). Keep all of them.
          filter = path: type:
            (builtins.match ".*\\.(txt|proto|vk|params|bin|json)$" path != null)
            || (builtins.match ".*/(genesis|proto)/.*" path != null)
            || (craneLib.filterCargoSources path type);
        };
        # The big C/C++ deps decide the toolchain: zebra-script wraps zcash_script
        # (C++) and librocksdb-sys builds rocksdb (C++) from source via cc-rs.
        # Both need a coherent clang + libc++ built against musl (gcc's libstdc++
        # references glibc-only symbols — __libc_single_threaded, *64 — that don't
        # exist in musl, which is exactly what a raw `cargo --target musl` build
        # hit).
        #
        # Pin clang 18, NOT the nixpkgs-unstable default (clang 21): clang 21 is
        # too strict for rocksdb 8.10 (librocksdb-sys 0.16.0+8.10.0) and rejects
        # its C++ with hard errors ("non-virtual member function marked 'override'
        # hides virtual member function", "out-of-line definition does not match
        # any declaration"). clang 18 compiles rocksdb 8.10 cleanly. (Zallet used
        # the clang-21 default fine because it has no rocksdb.)
        # pkgsMusl.llvmPackages_18 exposes `stdenv` (clang) and `libcxxStdenv`
        # (clang + libc++) — NOT `clangStdenv` (that attr only exists on the
        # default llvmPackages). We want libc++ for the musl C++ link, so use
        # libcxxStdenv.cc.
        baseCC = pkgs.pkgsMusl.llvmPackages_18.libcxxStdenv.cc;
        # rocksdb 8.10 (librocksdb-sys 0.16) uses uint64_t/int64_t without
        # including <cstdint>; gcc pulls it transitively (so ZFND, who build
        # rocksdb with gcc, never hit this), but clang+libc++ — which we NEED for
        # the musl/libc++ link — no longer does, giving "unknown type name
        # 'uint64_t'". The override/abstract-class errors cascade from that.
        #
        # Injecting the header via cargo CXXFLAGS_<target> or NIX_CFLAGS_COMPILE
        # did NOT reach rocksdb's compiles (crane's buildDepsOnly env didn't
        # propagate / librocksdb-sys's build.rs sets its own cc-rs flags). So bake
        # `-include` into a cc/c++ WRAPPER that rocksdb invokes directly — it
        # can't be bypassed. stdint.h for cc (C TUs: lz4/snappy), cstdint for c++.
        # The wrapper must NOT add -include to assembly (.S) compiles — ring
        # builds .S files, and injecting a C header there breaks the assembler
        # ("unexpected token in argument list" from alltypes.h). Only inject the
        # header when no .S/.s/.asm source is in the args.
        clangCC = pkgs.runCommand "zebra-clang-cstdint" { } ''
          mkdir -p $out/bin
          cat > $out/bin/cc  <<EOF
          #!${pkgs.runtimeShell}
          for a in "\$@"; do case "\$a" in *.S|*.s|*.asm) exec ${baseCC}/bin/cc "\$@";; esac; done
          exec ${baseCC}/bin/cc -include stdint.h "\$@"
          EOF
          cat > $out/bin/c++ <<EOF
          #!${pkgs.runtimeShell}
          for a in "\$@"; do case "\$a" in *.S|*.s|*.asm) exec ${baseCC}/bin/c++ "\$@";; esac; done
          exec ${baseCC}/bin/c++ -include cstdint "\$@"
          EOF
          chmod +x $out/bin/cc $out/bin/c++
        '';
        commonArgs = {
          inherit src;
          strictDeps = true;
          # zebrad release binary features (matches default-release-binaries).
          cargoExtraArgs = "--locked --package zebrad --bin zebrad";
          CARGO_BUILD_TARGET = muslTarget;
          # Static musl; use the musl clang as the linker so libc++ + crt resolve
          # coherently.
          CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static -C codegen-units=1 -C linker=${clangCC}/bin/cc -C link-arg=-static";
          # protoc for tonic-build (zebra-rpc/zebrad); clang for bindgen/*-sys;
          # git because zebrad/build.rs + zebra-rpc/build.rs embed the commit.
          nativeBuildInputs = with pkgs; [ protobuf llvmPackages_18.clang pkg-config git ];
          LIBCLANG_PATH = "${pkgs.llvmPackages_18.libclang.lib}/lib";
          PROTOC = "${pkgs.protobuf}/bin/protoc";
          doCheck = false;
        } // {
          # point cc-rs at the wrapped cc/c++ (which inject the cstdint header).
          "CC_${targetEnvSuffix}" = "${clangCC}/bin/cc";
          "CXX_${targetEnvSuffix}" = "${clangCC}/bin/c++";
        };
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        zebrad = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });
      in {
        packages.default = zebrad;
        packages.zebrad = zebrad;
        # deps-only output so the prebake cache can warm the toolchain closure.
        packages.deps = cargoArtifacts;
      });
}
