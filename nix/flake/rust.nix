{ inputs, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    let
      inherit (pkgs) lib;

      # --- toolchain -------------------------------------------------------
      # rust-version = "1.91" + edition 2024. Pin the exact stable toolchain
      # from fenix so a nixpkgs rustc bump can't silently change the compiler.
      # Two layers: `rustToolchain` (rustc+cargo) for the lean build closure,
      # `rustToolchainDev` (adds clippy/rustfmt/rust-analyzer) for the shell +
      # the clippy check.
      fenix = inputs.fenix.packages.${system};
      rustVersion = "1.91.0";

      # `toolchainOf` pins one released stable toolchain by version+hash.
      # It exposes the individual component drvs (rustc/cargo/clippy/…) and a
      # `.toolchain` that bundles them all — there's no `.minimal` here (that's
      # only on the channel aliases like `fenix.stable`).
      toolchain = fenix.toolchainOf {
        channel = rustVersion;
        # Update on toolchain bumps: set to lib.fakeSha256, run `nix build`,
        # and paste the "got:" hash it prints back here.
        sha256 = "sha256-2eWc3xVTKqg5wKSHGwt1XoM/kUBC6y3MWfKg74Zn+fY=";
      };

      # Build layer: just rustc + cargo (lean closure).
      rustToolchain = fenix.combine [
        toolchain.rustc
        toolchain.cargo
      ];
      # Dev layer: full toolchain (adds clippy/rustfmt/rust-analyzer/rust-src).
      rustToolchainDev = fenix.combine [
        toolchain.rustc
        toolchain.cargo
        toolchain.clippy
        toolchain.rustfmt
        toolchain.rust-src
        fenix.rust-analyzer
      ];

      craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;
      # clippy/rustfmt derivations need those components on PATH.
      craneLibDev = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchainDev;

      # --- source ----------------------------------------------------------
      # crane's default filter keeps only Cargo-recognised sources (*.rs +
      # manifests + lock). But the crate `include_str!`s a few data files at
      # compile time — `src/cli/gui.html` and the `contrib/` service units —
      # so those must be added back or the build fails with "couldn't read …".
      root = ../../.;
      extraFiles = [
        "src/cli/gui.html"
        "contrib/rayfish.service"
        "contrib/com.rayfish.vpn.plist"
      ];
      src = lib.cleanSourceWith {
        src = root;
        filter =
          path: type:
          (craneLib.filterCargoSources path type) || builtins.any (f: lib.hasSuffix f path) extraFiles;
        name = "rayfish-source";
      };

      # git short SHA for the version stamp. Prefer the flake's own rev so the
      # binary reports the right commit; fall back to "nix" out of a checkout.
      gitSha = inputs.self.shortRev or inputs.self.dirtyShortRev or "nix";

      commonArgs = {
        inherit src;
        strictDeps = true;

        # The iroh fork lives in Cargo.lock as `git+…`. crane vendors it from
        # the lock; no allowBuiltinFetchGit / impure network at build time.
        # (fetchCargoVendor is crane's default vendoring path.)

        nativeBuildInputs = [
          pkgs.pkg-config
        ];

        buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          # rtnetlink/zbus talk over sockets (pure Rust) but the iroh/dns
          # stack still wants a resolver at link time on some setups.
        ];
        # NB: no Darwin branch. `systems` is default-linux, so mac never
        # builds; and the old `darwin.apple_sdk.frameworks.*` attrs are
        # removed in current nixpkgs (the SDK is propagated by stdenv now).
        # Re-add a Darwin path here — using `pkgs.apple-sdk` — if/when a
        # darwin system is added to `flake.nix`.

        # build.rs reads `git rev-parse` and falls back to "unknown"; feed the
        # real SHA so nightly/report show the right commit without a .git dir.
        RAY_GIT_SHA = gitSha;

        # TLS is rustls+ring (see Cargo.toml). No OpenSSL, no aws-lc C build.
        # If a transitive dep ever pulls openssl-sys, uncomment:
        # OPENSSL_NO_VENDOR = "1";
        # and add pkgs.openssl to buildInputs.
      };

      # Dependency-only layer: the expensive, rarely-invalidated derivation.
      # Rebuilt only when Cargo.lock / manifests change, not on source edits.
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      # The `ray` binary. `desktop` is the default feature set (TUN daemon,
      # mesh ssh, self-update); the workspace also has ray-proto / ray-mobile.
      rayfish = craneLib.buildPackage (
        commonArgs
        // {
          inherit cargoArtifacts;
          pname = "rayfish";
          # Build only the binary crate + its bin; ray-mobile is Android-only
          # and pulls uniffi — leave it to the dedicated cargo-ndk flow.
          # (crane adds `--locked` itself; don't repeat it.)
          cargoExtraArgs = "-p rayfish --bin ray";
          doCheck = false; # tests run in the checks.* derivations below

          meta = {
            description = "P2P mesh VPN powered by iroh";
            homepage = "https://github.com/rayfish/rayfish";
            license = lib.licenses.mpl20;
            mainProgram = "ray";
            platforms = lib.platforms.unix;
          };
        }
      );
    in
    {
      packages = {
        inherit rayfish;
        default = rayfish;
      };

      # `nix flake check` — reuse cargoArtifacts so checks don't rebuild deps.
      checks = {
        inherit rayfish;

        clippy = craneLibDev.cargoClippy (
          commonArgs
          // {
            inherit cargoArtifacts;
            # --all-features so the lint pass also covers the optional `tor`
            # (iroh-tor-transport) and `otel` (opentelemetry/OTLP) surfaces,
            # not just the default `desktop` set — otherwise a break behind
            # those gates would sail through CI.
            cargoClippyExtraArgs = "--all-targets --all-features -- -D warnings";
          }
        );

        # crane already threads `--locked` into every cargo invocation, so
        # cargoTest/cargoClippy need no extra locking flag.
        test = craneLib.cargoTest (commonArgs // { inherit cargoArtifacts; });

        doc = craneLib.cargoDoc (commonArgs // { inherit cargoArtifacts; });
      };

      apps.default = {
        type = "app";
        program = "${lib.getExe rayfish}";
        meta.description = "Run the `ray` mesh-VPN CLI/daemon";
      };

      devShells.default = craneLibDev.devShell {
        inherit (commonArgs) RAY_GIT_SHA;
        checks = { }; # skip building checks just to enter the shell
        # craneLibDev.devShell already puts the dev toolchain on PATH.
        packages = [
          pkgs.cargo-nextest
          pkgs.cargo-ndk # Android .so builds (ray-mobile)
          pkgs.cargo-cross # `just cross` / `just cross-musl`
          pkgs.just
          pkgs.pkg-config
        ];
        inputsFrom = [ rayfish ];
      };
    };
}
