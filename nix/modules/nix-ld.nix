{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.nixLd;
in {
  options.krg.nixLd = {
    enable = mkEnableOption "nix-ld for running dynamically-linked non-NixOS binaries";

    # Extra libraries appended to the default set.
    # Useful for conda environments, MATLAB, proprietary research tools, etc.
    extraLibraries = mkOption {
      type        = types.listOf types.package;
      default     = [];
      description = "Additional libraries exposed to nix-ld-managed binaries";
    };
  };

  config = mkIf cfg.enable {
    programs.nix-ld = {
      enable    = true;
      libraries = with pkgs; [
        stdenv.cc.cc.lib   # libstdc++, libgcc_s
        glibc
        openssl
        zlib
        curl
        glib
        libGL
        libGLU
        freeglut
        xorg.libX11
        xorg.libXext
        xorg.libXrender
        xorg.libXi
        xorg.libXrandr
        expat
        freetype
        fontconfig
        # Common ML/research tool deps
        libffi
        bzip2
        ncurses5
        readline
      ] ++ cfg.extraLibraries;
    };
  };
}
