{
  config,
  lib,
  options,
  ...
}:
with builtins // lib; let
  cfg = config.nix.remote-builder;
  opt = options.nix.remote-builder;
  userOpts = options.users.users.type.getSubOptions [];
in {
  options.nix.remote-builder = with types; {
    inherit (userOpts.openssh.authorizedKeys) keyFiles keys;
    shell = userOpts.shell // {default = config.programs.rush.shell;};
    username = userOpts.name // {default = "nix-remote-builder";};

    enable = mkOption {
      type = bool;
      default = (cfg.keyFiles ++ cfg.keys) != [];
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (cfg.shell == opt.shell.default) {
      assertions = [
        {
          assertion = config.programs.rush.enable;
          message = "# TODO!";
        }
      ];

      programs.rush = {
        enable = mkDefault true;

        # TODO: explore systemd-inhibit usage;
        rules."nix-remote-builder" = ''
          clrenv
          keepenv PATH
          match $command ~ "^nix-(daemon|store)"
          match $user == "${cfg.username}"
          insert [0] = "${config.environment.usrbinenv}"
          insert [1] = "-S"
        '';
      };
    })

    {
      nix.settings.trusted-users = [cfg.username];
      users.groups."${cfg.username}" = {};

      assertions = [
        {
          assertion = config.services.openssh.enable;
          message = "The remote builder uses depends on {option}`services.openssh` to work. Please enable it.";
        }
      ];

      users.users."${cfg.username}" = {
        inherit (cfg) shell;
        group = "${cfg.username}";
        isSystemUser = true;
        openssh.authorizedKeys = {inherit (cfg) keyFiles keys;};
      };

      services.openssh.extraConfig = ''
        Match User ${cfg.username}
          AllowAgentForwarding no
          AllowTcpForwarding no
          PermitTTY no
          PermitTunnel no
          X11Forwarding no
        Match All
      '';
    }
  ]);
}
