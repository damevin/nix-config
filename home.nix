{ config, pkgs, ... }:

let
  # SecretSpec 0.18 is incompatible with pass-cli >= 2.2.4.
  # Remove this pin once nixpkgs ships SecretSpec >= 0.19.
  protonPassCli = pkgs.proton-pass-cli.overrideAttrs (old: {
    version = "2.2.3";

    src = pkgs.fetchurl {
      url = "https://proton.me/download/pass-cli/2.2.3/pass-cli-macos-aarch64";
      hash = "sha256-gxjlrznYmXgCFOxixtHCz9x2KLsgNtuo9yr3TJpjxzI=";
    };
  });

  opencodeWithSecrets = pkgs.writeShellScriptBin "opencode" ''
    export SECRETSPEC_PROTONPASS_CLI_PATH="${protonPassCli}/bin/pass-cli"

    exec ${pkgs.secretspec}/bin/secretspec \
           --file "$HOME/nix-config/config/secretspec/opencode/secretspec.toml" \
           run -- \
           ${pkgs.opencode}/bin/opencode "$@"
  '';
in

{
  home.username = "raphaeldamevin";
  home.homeDirectory = "/Users/raphaeldamevin";

  home.packages = with pkgs; [
    eza
    zoxide
    bat
    fd
    neovim
    ripgrep
    television
    coreutils
    wget
    tmux
    lazygit
    go
    protobuf
    pre-commit
    bazelisk
    ghostscript
    mkcert
    awscli2
    phrase-cli
    worktrunk
    shared-mime-info
    codex
    ssm-session-manager-plugin
    secretspec
    raycast
    obsidian
    protonPassCli
    opencodeWithSecrets
    nixfmt
    postgresql
    nil
    statix
    deadnix
    pnpm
    nodejs_24
  ];

  home.file.".config/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/nvim";

  home.file.".config/sketchybar".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/sketchybar";

  home.file.".config/karabiner/karabiner.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/karabiner/karabiner.json";

  home.file.".config/karabiner/assets/complex_modifications".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/karabiner/assets/complex_modifications";

  home.file.".config/rio".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/rio";

  home.file.".config/opencode/opencode.jsonc".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/opencode/opencode.jsonc";

  home.file.".config/zed/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/zed/settings.json";

  home.file.".config/zed/tasks.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/zed/tasks.json";

  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.kimi-code/bin"
  ];

  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "https";
      editor = "";
      prompt = "enabled";
      prefer_editor_prompt = "disabled";
      pager = "";
      http_unix_socket = "";
      browser = "";
      color_labels = "disabled";
      accessible_colors = "disabled";
      accessible_prompter = "disabled";
      spinner = "enabled";
      telemetry = "enabled";
    };
    gitCredentialHelper.enable = false;

  };

  programs.zsh = {
    enable = true;

    shellAliases = {
      ls = "eza --icons=auto";
      ll = "eza -lh --icons=auto --git";
      la = "eza -la --icons=auto --git";
      zed = "zeditor";
      cat = "bat";
      find = "fd";
      v = "nvim";
    };

    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";
      plugins = [ "git" ];
    };

    plugins = [
      {
        name = "fzf-tab";
        src = pkgs.zsh-fzf-tab;
        file = "share/fzf-tab/fzf-tab.plugin.zsh";
      }
    ];

    autosuggestion = {
      enable = true;
    };
    profileExtra = ''
      if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      fi
    '';

    initContent = ''
        function rio_title() {
          print -Pn "\e]0;%1~\a"
        }

      autoload -Uz add-zsh-hook
        add-zsh-hook precmd rio_title
        add-zsh-hook chpwd rio_title

      if command -v wt >/dev/null 2>&1; then
        eval "$(command wt config shell init zsh)"
      fi
    '';
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    historyWidget.command = "";
  };
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };
  programs.atuin = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      enter_accept = true;
    };
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  programs.aerospace = {
    enable = true;
    launchd.enable = true;
  };
  programs.zed-editor = {
    enable = true;
  };
  home.stateVersion = "26.05";

}
