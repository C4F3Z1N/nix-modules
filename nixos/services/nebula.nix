{
  config,
  lib,
  modulesPath,
  pkgs,
  options,
  ...
}:
with builtins // lib; let
  inherit (config.networking) enableIPv6;
  cfg = config.services.nebula;
  opt = options.services.nebula;
  format = pkgs.formats.yaml {};

  nebulaConfig.type = with types;
    submodule ({config, ...}: {
      freeformType = format.type;

      options = {
        pki = {
          ca = mkOption {
            type = path;
            default = "/etc/nebula/ca.crt";
          };

          cert = mkOption {
            type = path;
            default = "/etc/nebula/host.crt";
          };

          key = mkOption {
            type = path;
            default = "/etc/nebula/host.key";
          };
        };

        static_host_map = mkOption {type = attrsOf (listOf singleLineStr);};

        lighthouse = {
          am_lighthouse = mkOption {
            type = bool;
            default = false;
          };

          serve_dns = mkOption {
            type = bool;
            default = config.lighthouse.am_lighthouse;
          };

          dns = {
            host = mkOption {
              type = singleLineStr;
              default = "127.0.0.42";
            };

            port = mkOption {
              type = port;
              default = 53;
            };
          };

          interval = mkOption {
            type = int;
            default = 60;
          };

          hosts = mkOption {
            type = listOf singleLineStr;
            default =
              if config.lighthouse.am_lighthouse
              then []
              else attrNames config.static_host_map;
          };
        };

        listen = {
          host = mkOption {
            type = singleLineStr;

            default =
              if enableIPv6
              then "[::]"
              else "0.0.0.0";
          };

          port = mkOption {
            type = port;

            default =
              if config.lighthouse.am_lighthouse
              then 4242
              else 0;
          };
        };

        routines = mkOption {
          type = int;
          default = 2;
        };

        punchy.punch = mkOption {
          type = bool;
          default = true;
        };

        relay = {
          am_relay = mkOption {
            type = bool;
            default = false;
          };

          use_relays = mkOption {
            type = bool;
            default = true;
          };
        };

        tun = {
          disabled = mkOption {
            type = bool;
            default = false;
          };

          dev = mkOption {
            type = singleLineStr;
            default = "nbl0";
          };

          drop_local_broadcast = mkOption {
            type = bool;
            default = false;
          };

          drop_multicast = mkOption {
            type = bool;
            default = false;
          };

          tx_queue = mkOption {
            type = int;
            default = 500;
          };

          mtu = mkOption {
            type = int;
            default = 1300;
          };

          routes = mkOption {
            type = listOf attrs;
            default = [];
          };

          unsafe_routes = mkOption {
            type = listOf attrs;
            default = [];
          };
        };

        logging = {
          level = mkOption {
            type = enum [
              "debug"
              "error"
              "fatal"
              "info"
              "panic"
              "warning"
            ];

            default = "info";
          };

          format = mkOption {
            type = enum ["json" "text"];
            default = "text";
          };
        };

        firewall = {
          outbound_action = mkOption {
            type = enum ["drop" "reject"];
            default = "drop";
          };

          inbound_action = mkOption {
            type = enum ["drop" "reject"];
            default = "drop";
          };

          conntrack = {
            tcp_timeout = mkOption {
              type = singleLineStr;
              default = "12m";
            };
            udp_timeout = mkOption {
              type = singleLineStr;
              default = "3m";
            };
            default_timeout = mkOption {
              type = singleLineStr;
              default = "10m";
            };
          };

          outbound = mkOption {
            type = listOf attrs;

            default = [
              {
                port = "any";
                proto = "any";
                host = "any";
              }
            ];
          };

          inbound = mkOption {
            type = listOf attrs;

            default = [
              {
                port = "any";
                proto = "icmp";
                host = "any";
              }
              {
                port = 443;
                proto = "tcp";
                host = "any";
              }
            ];
          };
        };
      };
    });
in {
  disabledModules = [(modulesPath + "/services/networking/nebula.nix")];

  options.services.nebula = with types; {
    enable = mkOption {
      type = bool;
      default = opt.config.isDefined;
    };

    config = mkOption {inherit (nebulaConfig) type;};
    package = mkPackageOption pkgs "nebula" {};

    details = mkOption {
      type = attrs;
      readOnly = true;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (!cfg.config.tun.disabled) {
      networking.firewall.trustedInterfaces = [cfg.config.tun.dev];
    })

    (mkIf (cfg.config.listen.port != 0) {
      networking.firewall.allowedUDPPorts = [cfg.config.listen.port];
    })

    (mkIf cfg.config.lighthouse.serve_dns {
      networking.firewall = genAttrs [
        "allowedTCPPorts"
        "allowedUDPPorts"
      ] (_: [cfg.config.lighthouse.dns.port]);
    })

    {
      environment.systemPackages = [cfg.package];
      users.groups.nebula = {};

      users.users.nebula = {
        inherit (config.users.users.nobody) shell;
        createHome = true;
        home = "/etc/nebula";
        group = "nebula";
        isSystemUser = true;
      };

      services.nebula.details = trivial.importJSON (
        pkgs.runCommand "nebula-cert-details" {buildInputs = [cfg.package pkgs.jq];}
        "nebula-cert print -json -path ${cfg.config.pki.cert} | jq '.details' | tee $out"
      );

      systemd.services.nebula = {
        unitConfig.StartLimitIntervalSec = 0; # ensure Restart=always is always honoured (networks can go down for arbitrarily long)
        after = ["basic.target" "network.target"];
        description = "Nebula overlay networking tool";
        wantedBy = ["multi-user.target"];
        wants = ["basic.target"];

        serviceConfig = rec {
          AmbientCapabilities = CapabilityBoundingSet;
          DeviceAllow = "/dev/net/tun rw";
          DevicePolicy = "closed";
          ExecReload = "${dirOf config.environment.usrbinenv}/kill -SIGHUP $MAINPID";
          ExecStartPre = "${ExecStart} -test";
          ExecStart = "${cfg.package}/bin/nebula -config " + format.generate "config.yaml" cfg.config;
          Group = "nebula";
          LockPersonality = true;
          NoNewPrivileges = true;
          NotifyAccess = "main";
          PrivateDevices = false; # needs access to /dev/net/tun
          PrivateTmp = true;
          PrivateUsers = false; # CapabilityBoundingSet needs to apply to the host namespace
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "strict";
          Restart = "always";
          RestrictNamespaces = true;
          RestrictSUIDSGID = true;
          SyslogIdentifier = "nebula";
          Type = "notify";
          UMask = "0027";
          User = "nebula";

          # experimental;
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 4;
          MemoryAccounting = true;
          MemoryMax = "25%";

          CapabilityBoundingSet =
            ["CAP_NET_ADMIN"]
            ++ lib.optional (any (port: port > 0 && port < 1024) [
              cfg.config.lighthouse.dns.port
              cfg.config.listen.port
            ]) "CAP_NET_BIND_SERVICE";
        };
      };
    }
  ]);
}
