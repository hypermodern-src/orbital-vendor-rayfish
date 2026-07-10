{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = {
    treefmt = {
      projectRootFile = "flake.nix";
      programs = {
        nixfmt.enable = true; # nix
        rustfmt.enable = true; # rust (uses the toolchain's rustfmt)
        # taplo is intentionally *off*: the Cargo.toml manifests carry dense
        # inline annotations and a deliberate one-line-per-dep layout that
        # taplo's wrapping would churn. Leave TOML formatting to humans.
      };
    };
  };
}
