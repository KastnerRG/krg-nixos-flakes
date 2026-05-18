{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.oecQualysTrellix;

  # FHS environment for running the proprietary installer script and the
  # agent binaries. The installer.sh uses standard Linux paths (bash, coreutils,
  # grep, curl, etc.) that NixOS doesn't expose globally.
  fhsEnv = pkgs.buildFHSEnv {
    name        = "oec-qualys-trellix-fhs";
    runScript   = "bash";
    targetPkgs  = p: with p; [
      glibc
      openssl
      libgcc.lib
      zlib
      xz
      curl
      bash
      coreutils
      gnugrep
      gawk
      gnused
      procps
      util-linux
      iproute2
    ];
    # Expose /etc/os-release with Ubuntu identity so the installer's OS check
    # passes when called with the "ubuntu" argument
    extraOutputsToInstall = [];
    profile = ''
      export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    '';
  };

  # Wrapper script placed on PATH that lets operators re-run the installer
  # manually: oec-install /path/to/oec-qualys-trellix.tar.gz
  installScript = pkgs.writeShellScriptBin "oec-install" ''
    set -euo pipefail
    ARCHIVE="''${1:-}"
    if [ -z "$ARCHIVE" ]; then
      echo "Usage: oec-install <path-to-oec-qualys-trellix.tar.gz>" >&2
      exit 1
    fi
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT
    echo "Extracting $ARCHIVE..."
    tar -xzf "$ARCHIVE" -C "$TMPDIR"
    INSTALLER=$(find "$TMPDIR" -name "installer.sh" | head -1)
    if [ -z "$INSTALLER" ]; then
      echo "installer.sh not found in archive" >&2
      exit 1
    fi
    chmod +x "$INSTALLER"
    echo "Running installer in FHS environment..."
    ${fhsEnv}/bin/oec-qualys-trellix-fhs "$INSTALLER" ubuntu
    echo "Done. Restart qualys-cloud-agent and xagt services."
  '';
in {
  options.krg.oecQualysTrellix = {
    enable = mkEnableOption "OEC Qualys Cloud Agent and Trellix (xagt) security monitoring";

    # Path to the installer archive. If non-null, the activation script will
    # run the installer automatically on first boot (when the binary is absent).
    # Obtain the archive from the lab's internal storage; it is not in the repo.
    installerArchive = mkOption {
      type        = types.nullOr types.path;
      default     = null;
      description = "Path to oec-qualys-trellix.tar.gz; null = manual install only";
    };

    # Installation paths used by the installer on Ubuntu; adjust if the lab's
    # version installs elsewhere.
    qualysBin = mkOption {
      type    = types.str;
      default = "/usr/local/qualys/cloud-agent/bin/qualys-cloud-agent";
    };

    trellixBin = mkOption {
      type    = types.str;
      default = "/opt/trellix/xagt/bin/xagt";
    };

    enableTrellix = mkOption {
      type    = types.bool;
      default = true;
    };
  };

  config = mkIf cfg.enable {
    # Make the FHS environment and helper script available on PATH
    environment.systemPackages = [ fhsEnv installScript ];

    # Automatically run the installer on first boot if the archive is provided
    # and the binary is not yet installed.
    system.activationScripts.oec-qualys-trellix = mkIf (cfg.installerArchive != null) {
      text = ''
        if [ ! -x "${cfg.qualysBin}" ]; then
          echo "OEC: Installing Qualys + Trellix agents from ${cfg.installerArchive}..."
          TMPDIR=$(mktemp -d)
          tar -xzf ${cfg.installerArchive} -C "$TMPDIR"
          INSTALLER=$(find "$TMPDIR" -name "installer.sh" | head -1)
          chmod +x "$INSTALLER"
          ${fhsEnv}/bin/oec-qualys-trellix-fhs "$INSTALLER" ubuntu || true
          rm -rf "$TMPDIR"
        fi
      '';
      deps = [ "specialfs" "users" ];
    };

    systemd.services.qualys-cloud-agent = {
      description = "Qualys Cloud Agent";
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      wantedBy    = [ "multi-user.target" ];
      # Only start if the binary was actually installed
      unitConfig.ConditionPathExists = cfg.qualysBin;
      serviceConfig = {
        Type            = "forking";
        ExecStart       = "${cfg.qualysBin} start";
        ExecStop        = "${cfg.qualysBin} stop";
        Restart         = "on-failure";
        RestartSec      = "30s";
        # Ensure the agent can find its own shared libraries
        Environment     = "LD_LIBRARY_PATH=/usr/local/qualys/cloud-agent/lib";
      };
    };

    systemd.services.xagt = mkIf cfg.enableTrellix {
      description = "Trellix Agent (xagt)";
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      wantedBy    = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = cfg.trellixBin;
      serviceConfig = {
        Type       = "forking";
        ExecStart  = "${cfg.trellixBin} start";
        ExecStop   = "${cfg.trellixBin} stop";
        Restart    = "on-failure";
        RestartSec = "30s";
      };
    };
  };
}
