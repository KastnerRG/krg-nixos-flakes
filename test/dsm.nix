# Pinned DSM rig inputs + the `dsm-vm` provisioning app.
#
# Pins (sha256 from `nix-prefetch-url`): the RR loader release and the DSM 7.3.2
# DS3622xs+ .pat. Pinning both keeps the rig from silently drifting to a newer DSM
# than prod — that's the point (ADR 0001 / docs/krg-prod-iac.md). Bump deliberately.
{ pkgs }:
let
  # RR loader (RROrg/rr) — supports broadwellnk on DSM 7.3.
  rrLoaderZip = pkgs.fetchurl {
    url = "https://github.com/RROrg/rr/releases/download/26.4.0/rr-26.4.0.img.zip";
    sha256 = "0likw579hixj88l6il0rm33cdfzj4zwxbc6xg07spzhcnlpmkril";
  };

  # DSM 7.3.2-86009 install image for DS3622xs+ (the emulated model). 399.61 MB.
  dsmPat = pkgs.fetchurl {
    url = "https://global.synologydownload.com/download/DSM/release/7.3.2/86009/DSM_DS3622xs%2B_86009.pat";
    sha256 = "0p6csrjms3gzcwaxlinsxcdabpr15bsrrp3806vdq2wjc5skd1qk";
    name = "DSM_DS3622xs_plus_86009.pat";
  };

  domainTemplate = ./domains/dsm-vm.xml;
in
pkgs.writeShellApplication {
  name = "dsm-vm";
  runtimeInputs = with pkgs; [ libvirt qemu unzip coreutils gnused ];
  text = ''
    # Provision + boot a DSM rig VM. Usage: dsm-vm [vm-name]   (default: dsm-prod-mirror)
    name="''${1:-dsm-prod-mirror}"
    work="''${KRG_DSM_RIG_DIR:-$HOME/.local/share/krg-dsm-rig}/$name"
    uri="qemu:///system"
    mkdir -p "$work"

    # Writable loader disk from the pinned (read-only) rr.img.
    if [ ! -f "$work/rr.img" ]; then
      unzip -o ${rrLoaderZip} -d "$work"
      chmod u+w "$work/rr.img"
    fi

    # Data disk DSM installs onto.
    [ -f "$work/data.qcow2" ] || qemu-img create -f qcow2 "$work/data.qcow2" 32G

    # Stage the pinned .pat so the RR menu can install offline (point RR at this file).
    cp -n ${dsmPat} "$work/DSM_DS3622xs+_86009.pat"

    # Render the libvirt domain from the repo template.
    sed -e "s|@VM_NAME@|$name|g" \
        -e "s|@BOOT_IMG@|$work/rr.img|g" \
        -e "s|@DATA_IMG@|$work/data.qcow2|g" \
        ${domainTemplate} > "$work/$name.xml"

    virsh -c "$uri" define "$work/$name.xml" >/dev/null
    virsh -c "$uri" start "$name"

    echo "Started '$name'."
    echo "  console:  virsh -c $uri console $name   (or open virt-manager)"
    echo "  RR menu:  pick DS3622xs+ / DSM 7.3, install from the staged .pat:"
    echo "            $work/DSM_DS3622xs+_86009.pat"
    echo "Then run the DSM wizard and snapshot as the dsm-prod-mirror baseline."
  '';
}
