{
  description = "Raphael's macOS configuration";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-zed.url = "github:NixOS/nixpkgs/ea9e3ef341e11c193537f674f821a99f9f436729";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    neru.url = "github:y3owk1n/neru";
  };
  outputs =
    {
      nixpkgs,
      nixpkgs-zed,
      nix-darwin,
      home-manager,
      neru,
      ...
    }:
    {
      darwinConfigurations."lvs-mac-cf7426" = nix-darwin.lib.darwinSystem {
        modules = [
          ./darwin.nix

          {
            nixpkgs.overlays = [ neru.overlays.default ];
          }

          neru.darwinModules.default
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.extraSpecialArgs = { inherit nixpkgs-zed; };
            home-manager.backupFileExtension = "backup";
            home-manager.users.raphaeldamevin = import ./home.nix;
          }
        ];
      };
    };
}
