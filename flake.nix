{
  description = "// straylight // rayfish";

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      perSystem =
        { system, ... }:
        {
          _module.args.pkgs = import inputs.nixpkgs { inherit system; };
        };

      imports = [ ./nix/flake ];
    };

  inputs = {
    nixpkgs.url = "github:sensenet-ai/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default-linux";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Toolchain provider: gives us the exact edition-2024 / 1.91 toolchain
    # instead of whatever rustc nixpkgs happens to ship.
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";

    # The builder: Cargo-native dep resolution + cached dependency-only layer.
    crane.url = "github:ipetkov/crane";
  };
}
