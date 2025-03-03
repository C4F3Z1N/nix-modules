{
  config,
  lib,
  modulesPath,
  options,
  pkgs,
  ...
}:
with builtins // lib; let
  cfg = config.nix.remote-builder;
  userOpts = options.users.users.type.getSubOptions [];
in {
  disabledModules = [(modulesPath + "/services/misc/nix-ssh-serve.nix")];

  options.nix.remote-builder = with types; {
    inherit (userOpts.openssh.authorizedKeys) keyFiles keys;
    shell = userOpts.shell // {default = config.security.wrapperDir + "/rush";};
    username = userOpts.name // {default = "nix-remote-builder";};

    enable = mkOption {
      type = bool;
      default = (cfg.keyFiles ++ cfg.keys) != [];
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (cfg.shell == config.security.wrapperDir + "/rush") {
      environment.etc."rush.rc".text = mkDefault ''
        rush 2.0

        rule nix-remote-builder
          clrenv
          keepenv PATH SSH_* TERM*
          match $command ~ "^nix-(daemon|store)"
          match $user == "${cfg.username}"
          insert [0] = "/run/current-system/sw/bin/env"
          insert [1] = "-S"
      '';

      security.wrappers.rush = mkDefault {
        inherit (config.security.wrappers.su) group owner permissions;
        setuid = true;

        source = getExe (pkgs.rush.overrideAttrs (prev: {
          configureFlags = ["--sysconfdir=/etc"];
          installFlags = ["sysconfdir=$(out)/etc"];
          meta.mainProgram = prev.pname;
        }));
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
