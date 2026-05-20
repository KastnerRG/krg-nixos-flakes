{ config, lib, ... }:
with lib;
let
  cfg = config.krg.firewall;
in {
  options.krg.firewall = {
    enable = mkEnableOption "KRG firewall (replaces UFW)";

    allowedTCPPorts = mkOption {
      type    = types.listOf types.port;
      default = [ 22 ];
    };

    allowedUDPPorts = mkOption {
      type    = types.listOf types.port;
      default = [];
    };

    # Ports only reachable from the KRG Prometheus scraping host.
    # Matches UFW rules: allow <port> from 132.239.95.67
    monitoringPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      description = "Ports open only to monitoringSourceIp (Prometheus scraping)";
    };

    monitoringSourceIp = mkOption {
      type    = types.str;
      default = "132.239.95.67";
    };

    allowRDP = mkOption {
      type        = types.bool;
      default     = false;
      description = "Open port 3389 for XRDP (waiter compute nodes)";
    };

    sshSources = mkOption {
      type        = types.listOf types.str;
      default     = [];
      description = ''
        If non-empty, SSH (port 22) is reachable ONLY from these CIDRs/IPs
        in-guest, instead of being globally open. Service hosts set this (mirrors
        the Proxmox perimeter); compute hosts leave it empty (public SSH,
        protected by key-only auth + fail2ban). Usually set via krg.base.serviceHost.
      '';
    };
  };

  config = mkMerge [
    # krg.firewall is the single switch for the OS firewall. Enabling it turns
    # on nftables + the rules below; disabling it (e.g. VMs where the hypervisor
    # owns the firewall) explicitly turns the NixOS firewall OFF rather than
    # letting it fall back to its restrictive enabled-by-default state.
    { networking.firewall.enable = cfg.enable; }

    (mkIf cfg.enable {
      # extraInputRules uses nftables syntax; enable the nftables backend
      networking.nftables.enable = true;

      networking.firewall = {
        # When sshSources is set, SSH (22) is source-restricted via the rules
        # below, so drop it from the globally-open port list.
        allowedTCPPorts =
          (if cfg.sshSources == []
           then cfg.allowedTCPPorts
           else filter (p: p != 22) cfg.allowedTCPPorts)
          ++ optional cfg.allowRDP 3389;
        allowedUDPPorts = cfg.allowedUDPPorts;

        # nftables rules: monitoring-port scraping (from monitoringSourceIp) and,
        # on service hosts, source-restricted SSH (from sshSources).
        extraInputRules =
          concatMapStringsSep "\n" (port: ''
            ip saddr ${cfg.monitoringSourceIp} tcp dport ${toString port} accept
          '') cfg.monitoringPorts
          + concatMapStringsSep "\n" (src: ''
            ip saddr ${src} tcp dport 22 accept
          '') cfg.sshSources;
      };
    })
  ];
}
