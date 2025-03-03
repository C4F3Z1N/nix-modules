{
  config,
  lib,
  pkgs,
  ...
}:
with builtins // lib; let
  indent = lines: "\n  " + (concatStringsSep "\n  " lines);
  sanitize = lines: filter (line: line != "") (splitString "\n" lines);
  cfg = config.programs.rush;

  cfgLinesType = with types;
    coercedTo lines sanitize (nonEmptyListOf singleLineStr);
in {
  options.programs.rush = with types; {
    enable = mkOption {
      type = bool;
      default = cfg.global != null || cfg.rules != {};
    };

    global = mkOption {
      type = nullOr cfgLinesType;
      default = null;
    };

    package = mkOption {
      type = shellPackage;

      default = pkgs.rush.overrideAttrs (prev: {
        configureFlags = ["--sysconfdir=/etc"];
        installFlags = ["sysconfdir=$(out)/etc"];
        meta.mainProgram = prev.pname;
      });
    };

    rules = mkOption {
      type = attrsOf cfgLinesType;
      default = {};
    };

    shell = mkOption {
      type = either shellPackage path;
      readOnly = true;
      default = cfg.package;
    };

    wrap = mkOption {
      type = bool;
      internal = true;
      default = true;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.wrap {
      programs.rush.shell = config.security.wrapperDir + "/rush";

      security.wrappers.rush = {
        inherit (config.security.wrappers.su) group owner permissions;
        setuid = true;
        source = getExe cfg.package;
      };
    })

    {
      environment = {
        shells = [cfg.shell];

        etc."rush.rc".text = mkMerge (flatten [
          (mkIf (versionAtLeast cfg.package.version "2.0") "rush 2.0")
          (mkIf (!isNull cfg.global) ("global" + indent cfg.global))
          (mapAttrsToList (name: lines: "rule ${name}" + indent lines)
            cfg.rules)
        ]);
      };
    }
  ]);
}
