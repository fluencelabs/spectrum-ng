{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    systems.url = "github:nix-systems/default";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          system = system;
        };
      in
      {
        formatter = pkgs.nixfmt-rfc-style;

        devShells.default = pkgs.mkShell {
          name = "spectrum-ng";

          packages = [
            pkgs.just
            pkgs.gh
            pkgs.kubectl
            pkgs.kubernetes-helm
            pkgs.kubevirt
            pkgs.fluxcd
            pkgs.nixfmt-rfc-style
          ];

          shellHook = ''
            [[ -f $FLUENCE_SECRETS ]] && source $FLUENCE_SECRETS
            [[ -f ./kubeconfig ]] && export KUBECONFIG=$(realpath ./kubeconfig)
            [[ -f ./talosconfig ]] && export TALOSCONFIG=$(realpath ./talosconfig)
          '';
        };
      }
    );
}
