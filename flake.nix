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
        src = craneLib.cleanCargoSource ./.;
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
        clangCC = pkgs.pkgsMusl.llvmPackages_18.clangStdenv.cc;
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
          "CC_${targetEnvSuffix}" = "${clangCC}/bin/cc";
          "CXX_${targetEnvSuffix}" = "${clangCC}/bin/c++";
          # rocksdb 8.10 (librocksdb-sys 0.16) was written before libc++/clang
          # stopped pulling <cstdint> in transitively, so its headers use
          # uint64_t/int64_t without including it → "unknown type name 'uint64_t'"
          # (and the override/abstract-class errors cascade from that). Force the
          # header in for every C/C++ TU of the *-sys crates via the per-target
          # cc-rs flags.
          "CFLAGS_${targetEnvSuffix}" = "-include stdint.h";
          "CXXFLAGS_${targetEnvSuffix}" = "-include cstdint";
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
