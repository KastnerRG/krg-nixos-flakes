{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.xrdp;
in {
  options.krg.xrdp = {
    enable = mkEnableOption "XRDP remote desktop with XFCE (waiter compute nodes)";

    # waiter xrdp/sesman.ini values
    maxSessions      = mkOption { type = types.int; default = 50; };
    maxLoginRetry    = mkOption { type = types.int; default = 4; };
    killDisconnected = mkOption { type = types.bool; default = true; };
  };

  config = mkIf cfg.enable {
    services.xrdp = {
      enable               = true;
      defaultWindowManager = "${pkgs.xfce.xfce4-session}/bin/xfce4-session";
      # Firewall is managed by krg.firewall (allowRDP = true opens 3389)
      openFirewall         = false;
    };

    services.xserver = {
      enable = true;
      desktopManager.xfce.enable = true;
    };

    environment.systemPackages = with pkgs; [
      xfce.xfce4-session
      xfce.xfwm4
      xfce.xfce4-panel
      firefox
    ];
  };
}
