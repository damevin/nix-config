{ pkgs, ... }:

let
  # Rio 0.5.10 has a macOS sandbox-incompatible test...
  rio = pkgs.rio.overrideAttrs (old: {
    checkFlags = (old.checkFlags or [ ]) ++ [
      "--skip=tests::drives_a_real_shell_and_reads_cells"
    ];
  });
in

{
  nixpkgs.hostPlatform = "aarch64-darwin";
  users.users.raphaeldamevin = {
    home = "/Users/raphaeldamevin";
  };
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (pkgs.lib.getName pkg) [
      "raycast"
      "obsidian"
    ];
  programs.zsh.enable = true;
  environment.systemPackages = with pkgs; [
    cowsay
    tree
    rio
    rio.terminfo
  ];
  services.tailscale.enable = true;
  environment.etc."resolver/ts.net".enable = false;
  services.sketchybar.enable = true;
  # TODO:: re-enable once nix-darwin supports karabiner-elements v15+
  # upstream: nix-darwin/nix-darwin#1679
  # the current module still expect the old launchd architecture.
  # services.karabiner-elements.enable = true;
  services.jankyborders = {
    enable = true;

    style = "round";
    width = 5.0;
    hidpi = true;

    active_color = "gradient(top_right=0xffFF2E93,bottom_left=0xff0058FF)";
    inactive_color = "0x00000000";
  };
  services.neru = {
    enable = true;
    configFile = ./config/neru/config.toml;
  };
  system.primaryUser = "raphaeldamevin";
  system.stateVersion = 6;
}
