{ pkgs, ... }:

{
  nixpkgs.hostPlatform = "aarch64-darwin";
  users.users.raphaeldamevin = {
    home = "/Users/raphaeldamevin";
  }
  environment.systemPackages = with pkgs; [
    cowsay
      tree
  ];
  system.stateVersion = 6;
}
