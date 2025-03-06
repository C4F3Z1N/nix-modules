{
  config,
  lib,
  options,
  pkgs,
  ...
}:
with builtins // lib; let
  cfg = config.services.host-gpg-agent;

  confFormat = pkgs.formats.keyValue {
    listsAsDuplicateKeys = true;

    mkKeyValue = key: value:
      if isString value
      then "${key} ${value}"
      else optionalString value key;
  };

  confFiles = {
    "gpg-agent.conf" = confFormat.generate "gpg-agent.conf" cfg.conf;
    "gpg.conf" = confFormat.generate "gpg.conf" {use-agent = true;};
  };
in {
  options.services.host-gpg-agent = with types; {
    enable = mkOption {
      type = bool;
      default = false;
    };

    conf = mkOption {
      inherit (confFormat) type;

      default = {
        disable-scdaemon = true;
        enable-ssh-support = true;
        pinentry-program = getExe config.programs.gnupg.agent.pinentryPackage;
      };
    };

    homedir = mkOption {
      type = path;
      default = config.users.users.root.home + "/.gnupg";
    };

    package =
      options.programs.gnupg.package
      // {default = config.programs.gnupg.package;};

    runtimedir = mkOption {
      type = path;
      default = "/run/host-gpg-agent";
    };

    sockets = mkOption {
      type = nonEmptyListOf (enum ["browser" "extra" "ssh" "std"]);

      apply = value:
        lists.unique (
          # ensure that "std" is always in this list;
          if elem "std" value
          then value
          else ["std"] ++ value
        );

      default = ["std"];
    };

    verbose = mkOption {
      type = bool;
      default = false;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (elem "ssh" cfg.sockets) {
      programs.ssh.extraConfig = ''
        Match localuser root
          IdentityAgent ${cfg.runtimedir}/S.gpg-agent.ssh
        Match All

        Match host * exec "gpg-connect-agent --quiet updatestartuptty /bye"
      '';

      services.openssh.extraConfig = "HostKeyAgent ${cfg.runtimedir}/S.gpg-agent.ssh";
    })

    {
      environment.systemPackages = [cfg.package];

      systemd = rec {
        services = {
          host-gpg-agent = rec {
            description = "GnuPG cryptographic agent and passphrase cache";
            documentation = ["man:gpg-agent(1)"];

            after = requires;
            environment.GNUPGHOME = cfg.homedir;
            path = [cfg.package];
            reloadTriggers = attrValues confFiles;
            requires = mapAttrsToList (name: _: "${name}.socket") sockets;
            unitConfig.RefuseManualStart = true;

            serviceConfig = {
              ExecReload = "${config.environment.usrbinenv} -S -- gpgconf --reload gpg-agent";
              ExecStart =
                "${config.environment.usrbinenv} -S -- gpg-agent --supervised"
                + optionalString cfg.verbose " --verbose";
            };
          };
        };

        sockets = listToAttrs (map (type: {
            name = "host-gpg-agent" + optionalString (type != "std") "-${type}";

            value =
              (
                if type == "ssh"
                then {
                  description = "GnuPG cryptographic agent (ssh-agent emulation)";
                  documentation = services.host-gpg-agent.documentation ++ ["man:ssh-add(1)" "man:ssh-agent(1)" "man:ssh(1)"];
                }
                else {
                  inherit (services.host-gpg-agent) documentation;
                  description = services.host-gpg-agent.description + optionalString (type != "std") " (${type})";
                }
              )
              // {
                partOf = ["host-gpg-agent.service"];
                wantedBy = ["sockets.target"];

                socketConfig = rec {
                  DirectoryMode = "0700";
                  FileDescriptorName = type;
                  ListenStream =
                    "${cfg.runtimedir}/S.gpg-agent"
                    + optionalString (type != "std") ".${type}";
                  RemoveOnStop = true;
                  Service = "host-gpg-agent.service";
                  SocketMode = "0600";
                  Symlinks = "${cfg.homedir}/${baseNameOf ListenStream}";
                };
              };
          })
          cfg.sockets);

        tmpfiles.rules = mapAttrsToList (name: path: "L+ ${cfg.homedir}/${name} - - - - ${path}") confFiles;
      };
    }
  ]);
}
