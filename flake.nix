{
  description = "Raphael's macOS configuration";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, nix-darwin, ... }:
  {
    darwinConfigurations."lvs-mac-cf7426" = 
      nix-darwin.lib.darwinSystem {
        modules = [
          ./darwin.nix
        ];
      };
  };
}
