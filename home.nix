{ config, pkgs, nixpkgs-zed, ... }:

let
  herdr-core = pkgs.callPackage ./pkgs/herdr-core.nix { };
  omp = pkgs.callPackage ./pkgs/omp.nix { };

  overseer = pkgs.applyPatches {
    name = "overseer-free-panels";
    src = pkgs.fetchFromGitHub {
      owner = "mmnavarr";
      repo = "overseer";
      rev = "5bc52f7fb5b7665ada4f060a66715d074c9822f5";
      hash = "sha256-UAyzCLk3QM10MEqv0SDc8TX6IvarxIzKxF5eCgIatl4=";
    };
    patches = [ ./config/tern/overseer-free-panels.patch ];
  };

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
           "$HOME/.opencode/bin/opencode" "$@"
  '';

  # entropy's .mcp.json starts `mcp-grafana` with a token file; this picks the token from SecretSpec by GRAFANA_URL instead.
  mcpGrafanaWithSecrets = pkgs.writeShellScriptBin "mcp-grafana" ''
    export SECRETSPEC_PROTONPASS_CLI_PATH="${protonPassCli}/bin/pass-cli"
    export SECRETSPEC_REASON="mcp-grafana read-only token"
    case "$GRAFANA_URL" in
      *staging*) name=GRAFANA_STAGING_TOKEN ;;
      *production*) name=GRAFANA_PRODUCTION_TOKEN ;;
    esac
    unset GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE

    exec ${pkgs.secretspec}/bin/secretspec \
           --file "$HOME/nix-config/config/secretspec/grafana/secretspec.toml" \
           run -- \
           sh -c 'export GRAFANA_SERVICE_ACCOUNT_TOKEN="$(printenv "$0")"; exec "$@"' "$name" \
           ${pkgs.mcp-grafana}/bin/mcp-grafana "$@"
  '';

  # Injects SLACK_MCP_CLIENT_SECRET, read by ~/.omp/agent/mcp.json as ${SLACK_MCP_CLIENT_SECRET}.
  ompWithSecrets = pkgs.writeShellScriptBin "omp" ''
    export SECRETSPEC_PROTONPASS_CLI_PATH="${protonPassCli}/bin/pass-cli"
    export SECRETSPEC_REASON="''${SECRETSPEC_REASON:-omp: Slack MCP OAuth client secret}"

    exec ${pkgs.secretspec}/bin/secretspec \
           --file "$HOME/nix-config/config/secretspec/omp/secretspec.toml" \
           run -- \
           ${omp}/bin/omp "$@"
  '';

  kimiCode = pkgs.stdenvNoCC.mkDerivation {
    pname = "kimi-code";
    version = "0.42.0";

    src = pkgs.fetchurl {
      url = "https://code.kimi.com/kimi-code/binaries/0.42.0/kimi-code-darwin-arm64";
      hash = "sha256-12T97ybxuxCMx0x/u0D9viP2fYxQfPk6L5+qTf+5+N8=";
    };

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      mkdir -p "$out/bin"
      cp "$src" "$out/bin/kimi"
      chmod +x "$out/bin/kimi"
    '';
  };

  linearTui = pkgs.buildGoModule {
    pname = "linear-tui";
    version = "unstable-2026-09-10";

    src = pkgs.fetchFromGitHub {
      owner = "roeyazroel";
      repo = "linear-tui";
      rev = "46a83904733b68e25c72093b83d628a89e2af33c";
      hash = "sha256-oS0hR5/gdTPfeICAMuJfkIxLTxOAfxe2K8Nq8N2WPsU=";
    };

    vendorHash = "sha256-+yC22fb6GtfAXLCIwwSXNRV7FIpelSx25KVa8NiD3Ew=";
    subPackages = [ "cmd/linear-tui" ];
  };

  slk = pkgs.buildGoModule {
    pname = "slk";
    version = "unstable-2026-09-10";

    src = pkgs.fetchFromGitHub {
      owner = "gammons";
      repo = "slk";
      rev = "976200c6f0730a8d07aa877d0e1eab6fa0bde232";
      hash = "sha256-30fDRuTRlprm9rtK+jurfv2dqOZpjwamYdcSi8FMuW0=";
    };

    vendorHash = "sha256-deqCUDgRvhe/Bpmy+9bIHjSBo+KTCtAN2XcGMhAj/G0=";
    subPackages = [ "cmd/slk" ];
  };
in

{
  home.username = "raphaeldamevin";
  home.homeDirectory = "/Users/raphaeldamevin";

  home.packages = with pkgs; [
    eza
    zoxide
    bat
    delta
    diffnav
    mpv
    yt-dlp
    fd
    neovim
    nodejs
    pnpm
    ripgrep
    television
    coreutils
    wget
    tmux
    taskwarrior3
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
    mcpGrafanaWithSecrets
    kimiCode
    ompWithSecrets
    herdr-core
    linearTui
    slk
    nixfmt
    nil
    statix
    deadnix
  ];

  home.file.".config/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/nvim";

  home.file.".config/sketchybar".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/sketchybar";

  home.file.".config/karabiner/karabiner.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/karabiner/karabiner.json";

  home.file.".config/karabiner/assets/complex_modifications".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/karabiner/assets/complex_modifications";

  home.file.".config/herdr-app/programs.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/programs.json";
  home.file.".config/herdr-app/layouts/agent-command-center.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/layouts/agent-command-center.json";
  home.file.".config/herdr-app/mods/acc-today".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-today";
  home.file.".config/herdr-app/mods/acc-routing".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-routing";
  launchd.agents = pkgs.lib.mapAttrs' (job: when: pkgs.lib.nameValuePair "acc-automation-${job}" {
    enable = true;
    config = {
      ProgramArguments = [ "/usr/bin/python3" "${config.home.homeDirectory}/nix-config/config/herdr-app/automation/run.py" job ];
      StartCalendarInterval = when;
      EnvironmentVariables.PATH = "${config.home.homeDirectory}/.local/bin:${config.home.homeDirectory}/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin";
      StandardOutPath = "${config.home.homeDirectory}/.local/state/acc-automation/launchd.log";
      StandardErrorPath = "${config.home.homeDirectory}/.local/state/acc-automation/launchd.log";
    };
  }) {
    weekly-recap = [ { Weekday = 5; Hour = 17; Minute = 0; } ];
    feedback-digest = map (Weekday: { inherit Weekday; Hour = 18; Minute = 0; }) (pkgs.lib.range 1 5);
    sentry-scout = pkgs.lib.concatMap (Weekday: [ { inherit Weekday; Hour = 9; Minute = 30; } { inherit Weekday; Hour = 15; Minute = 0; } ]) (pkgs.lib.range 1 5);
    daily-brief = map (Weekday: { inherit Weekday; Hour = 10; Minute = 0; }) (pkgs.lib.range 1 5);
    slack-pings = pkgs.lib.concatMap (Weekday: pkgs.lib.concatMap (Hour: map (Minute: { inherit Weekday Hour Minute; }) [ 0 30 ]) (pkgs.lib.range 9 18)) (pkgs.lib.range 1 5);
  };

  home.file.".config/herdr-app/mods/acc-review".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-review";
  home.file.".config/herdr-app/mods/acc-break".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-break";
  home.file.".config/herdr-app/mods/acc-md".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-md";
  home.file.".config/herdr-app/mods/acc-automation".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-automation";
  home.file.".config/herdr-app/mods/acc-new-menu".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-new-menu";
  home.file.".config/herdr-app/mods/acc-note".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-note";
  home.file.".config/herdr-app/mods/acc-tabs".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/acc-tabs";
  home.file.".config/herdr-app/mods/usage-limits".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/herdr-app/mods/usage-limits";

  # GUI-launched Tern may omit the Nix profile from PATH. Overseer also searches
  # ~/.local/bin directly, so expose the managed Worktrunk binary there.
  home.file.".local/bin/wt".source = "${pkgs.worktrunk}/bin/wt";

  home.file."Library/Application Support/Tern/plugins/overseer.path".text = "${overseer}";
  home.file."Library/Application Support/Tern/plugins/acc.path".text =
    "${config.home.homeDirectory}/nix-config/config/tern/acc";

  home.file.".config/rio".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/rio";

  home.file.".config/opencode/opencode.jsonc".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/opencode/opencode.jsonc";

  home.file.".config/gh-dash/config.yml".text = ''
    prSections:
      - title: "My PRs"
        filters: "is:open author:@me repo:livestorm/entropy"
      - title: "Need My Review"
        filters: "is:open review-requested:@me repo:livestorm/entropy"
      - title: "CI failing"
        filters: "is:open author:@me status:failure repo:livestorm/entropy"
      - title: "CI pending"
        filters: "is:open author:@me status:pending repo:livestorm/entropy"
      - title: "Ready to merge"
        filters: "is:open author:@me review:approved -draft:true repo:livestorm/entropy"
    pager:
      diff: delta
    repoPaths:
      "livestorm/*": "${config.home.homeDirectory}/Documents/livestorm/*"
      "damevin/*": "${config.home.homeDirectory}/projects/*"
      "damevin/nix-config": "${config.home.homeDirectory}/nix-config"
    keybindings:
      prs:
        - key: g
          name: lazygit
          command: cd "{{.RepoPath}}" && lazygit
        - key: v
          name: lazyvim
          command: cd "{{.RepoPath}}" && nvim .
        - key: d
          name: diff with delta
          command: gh pr diff {{.PrNumber}} --repo {{.RepoName}} | delta --paging=always
  '';

  home.file.".config/slk/config.toml".text = ''
    [appearance]
    image_protocol = "off"

    [workspaces.livestorm]
    team_id = "T039T7X11"
    version_ts = "1789013251"
  '';

  home.file.".config/zed/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/zed/settings.json";

  home.file.".config/zed/tasks.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/config/zed/tasks.json";

  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.rbenv/bin"
    "$HOME/.bun/bin"
  ];

  programs.git.settings = {
    push.autoSetupRemote = true;
  };

  programs.gh = {
    enable = true;
    extensions = [ pkgs.gh-dash pkgs.gh-stack ];
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
      gdash = "gh dash";
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
            export NVM_DIR="$HOME/.nvm";
      if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        source "$NVM_DIR/nvm.sh"
          fi
          if [[ -s "$NVM_DIR/bash_completion" ]]; then
            source "$NVM_DIR/bash_completion"
              fi
    '';
    initContent = ''
        function rio_title() {
          print -Pn "\e]0;%1~\a"
        }

      autoload -Uz add-zsh-hook
        add-zsh-hook precmd rio_title
        add-zsh-hook chpwd rio_title
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
  programs.aerospace = {
    enable = true;
    launchd.enable = true;
    settings = {
      config-version = 2;
      start-at-login = true;
      persistent-workspaces = [ "1" "2" "3" "4" "5" "10" ];
      on-focus-changed = [
        "exec-and-forget ${config.home.homeDirectory}/.config/sketchybar/plugins/aerospace-workspace-change.sh"
      ];

      gaps = {
        inner.horizontal = 10;
        inner.vertical = 10;
        outer.left = 10;
        outer.bottom = 10;
        outer.top = [
          { monitor."Built-in Retina Display" = 0; }
          40
        ];
        outer.right = 10;
      };

      workspace-to-monitor-force-assignment = {
        "1" = "main";
        "2" = "main";
        "3" = "main";
        "4" = "main";
        "5" = "main";
        "10" = [ "secondary" "main" ];
      };

      on-window-detected = [
        {
          "if" = "test %{app-bundle-id} = com.apple.systempreferences";
          run = "layout floating";
        }
        {
          "if".app-name-regex-substring = "mpv";
          run = "layout floating";
        }
      ];

      mode.main.binding = {
        "alt-h" = "focus left";
        "alt-j" = "focus down";
        "alt-k" = "focus up";
        "alt-l" = "focus right";
        "alt-left" = "focus-monitor left";
        "alt-right" = "focus-monitor right";

        "alt-shift-h" = "move left";
        "alt-shift-j" = "move down";
        "alt-shift-k" = "move up";
        "alt-shift-l" = "move right";
        "alt-shift-left" = "move-node-to-monitor left";
        "alt-shift-right" = "move-node-to-monitor right";
        "alt-minus" = "resize smart -50";
        "alt-equal" = "resize smart +50";
        "alt-shift-minus" = "resize height -50";
        "alt-shift-equal" = "resize height +50";

        "ctrl-alt-h" = "join-with left";
        "ctrl-alt-j" = "join-with down";
        "ctrl-alt-k" = "join-with up";
        "ctrl-alt-l" = "join-with right";

        "alt-1" = "workspace 1";
        "alt-2" = "workspace 2";
        "alt-3" = "workspace 3";
        "alt-4" = "workspace 4";
        "alt-5" = "workspace 5";
        "alt-0" = "workspace 10";
        "alt-shift-1" = "move-node-to-workspace 1";
        "alt-shift-2" = "move-node-to-workspace 2";
        "alt-shift-3" = "move-node-to-workspace 3";
        "alt-shift-4" = "move-node-to-workspace 4";
        "alt-shift-5" = "move-node-to-workspace 5";

        "alt-shift-space" = "layout floating tiling";
        "alt-shift-f" = "layout tiles horizontal vertical";
        "alt-shift-r" = "flatten-workspace-tree";
        "alt-shift-0" = "move-node-to-workspace 10";
      };
    };
  };
  programs.zed-editor = {
    enable = true;
    package = nixpkgs-zed.legacyPackages.${pkgs.stdenv.hostPlatform.system}.zed-editor;
  };
  targets.darwin.copyApps.enable = false;
  targets.darwin.linkApps.enable = true;
  home.stateVersion = "26.05";

}
