{ ... }:
let
  # Referencing the directory (not individual files) ensures Docker Compose
  # `include:` directives can resolve sibling compose files from the same
  # Nix store path, and lets us symlink config subdirs from the working dir.
  composeDir = ../../docker-compose/krg-prod;
in {
  imports = [
    ../../profiles/server.nix
    ./hardware-configuration.nix
  ];

  # KRG lab-wide production host (the old "fabricant" services). E4E
  # project-specific services live on the separate e4e-prod host.
  krg.adminAccount = "krg-admin";

  # Proxmox VM. The in-guest NixOS firewall stays ON (base.nix runs it on every
  # host) — isVM just enables the QEMU guest agent. Defense-in-depth: ports/SSH
  # are restricted in-guest AND at the Proxmox perimeter (not "firewall off").
  krg.base.isVM = true;

  networking = {
    hostName = "krg-prod";
    domain   = "ucsd.edu";
  };

  # label_studio_admin group (from the old fabricant-prod label_studio.yaml)
  users.groups.label_studio_admin = {};

  systemd.tmpfiles.rules = [
    # ── Shared host storage ───────────────────────────────────────────────
    # Shared Label Studio file storage; mounted into the container as /data
    "d /share/label-studio/files 0777 root root -"

    # ── Working directory layout under /var/lib/krg/krg-prod/ ─────────────
    # (the compose-stack module already creates /var/lib/krg/krg-prod/ and .secrets/)

    # Read-only config dirs: symlink from working dir → Nix store.
    # Docker bind-mount follows symlinks so ./prometheus resolves to the store path.
    "L /var/lib/krg/krg-prod/prometheus          - - - - ${composeDir}/prometheus"
    "L /var/lib/krg/krg-prod/blackbox-exporter   - - - - ${composeDir}/blackbox-exporter"
    "L /var/lib/krg/krg-prod/grafana             - - - - ${composeDir}/grafana"

    # Loki: separate read-only config files from writable data dir
    "d  /var/lib/krg/krg-prod/loki                          0750 1000 1000 -"
    "L  /var/lib/krg/krg-prod/loki/loki-config.yaml         - - - - ${composeDir}/loki/loki-config.yaml"
    "L  /var/lib/krg/krg-prod/loki/promtail-config.yaml     - - - - ${composeDir}/loki/promtail-config.yaml"
    "d  /var/lib/krg/krg-prod/loki/loki-data                0750 1000 1000 -"

    # Label-studio postgres: config (read-only symlinks) + data (writable)
    "d  /var/lib/krg/krg-prod/postgres                      0750 root   docker -"
    "L  /var/lib/krg/krg-prod/postgres/config               - - - - ${composeDir}/postgres/config"
    "L  /var/lib/krg/krg-prod/postgres/scripts              - - - - ${composeDir}/postgres/scripts"
    "d  /var/lib/krg/krg-prod/postgres/data                 0750 1000 1000 -"

    # Authentik postgres: same pattern
    "d  /var/lib/krg/krg-prod/authentik                     0750 root   docker -"
    "d  /var/lib/krg/krg-prod/authentik/postgres            0750 root   docker -"
    "L  /var/lib/krg/krg-prod/authentik/postgres/config     - - - - ${composeDir}/authentik/postgres/config"
    "L  /var/lib/krg/krg-prod/authentik/postgres/scripts    - - - - ${composeDir}/authentik/postgres/scripts"
    "d  /var/lib/krg/krg-prod/authentik/postgres/data       0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/media               0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/data                0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/certs               0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/custom-templates    0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/proxy-tmp           0750 root  root -"

    # Outline: docker.env is read-only; data dirs are writable
    "d  /var/lib/krg/krg-prod/outline                       0750 root   docker -"
    "L  /var/lib/krg/krg-prod/outline/docker.env            - - - - ${composeDir}/outline/docker.env"
    "d  /var/lib/krg/krg-prod/outline/outline_data          0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/outline/postgres              0750 1000 1000 -"

    # MLflow: working dir for postgres data volumes; config/Dockerfile is in the Nix store
    "d  /var/lib/krg/krg-prod/mlflow                        0750 root   docker -"
    "L  /var/lib/krg/krg-prod/mlflow/config                 - - - - ${composeDir}/mlflow/config"

    # Grafana, Prometheus data (writable)
    "d  /var/lib/krg/krg-prod/grafana-storage               0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/prometheus-data               0750 1000 1000 -"

    # Label Studio data
    "d  /var/lib/krg/krg-prod/label_studio_data_pg          0750 1000 1000 -"

    # Traefik TLS certificate storage
    "d  /var/lib/krg/krg-prod/traefik-data                  0750 root docker -"
    "d  /var/lib/krg/krg-prod/traefik-data/letsencrypt      0750 root docker -"
  ];

  # krg-prod runs as a single compose project (compose.yml uses `include:` to
  # bring in authentik, grafana, label-studio, mlflow, and outline stacks).
  #
  # Secrets required in /var/lib/krg/krg-prod/.secrets/ before starting:
  #   authentik_postgres_admin_password.txt
  #   authentik_admin_password.env      (AUTHENTIK_SECRET_KEY=... AUTHENTIK_POSTGRESQL__PASSWORD=...)
  #   authentik_traefik_token.env
  #   gf_admin_password.txt
  #   label_studio_admin_password_pg.env
  #   postgres_admin_password.txt       (for label-studio postgres)
  #   outline_secrets.env               (SECRET_KEY, UTILS_SECRET, OIDC_CLIENT_SECRET, DATABASE_URL, ...)
  #   mlflow.env                        (POSTGRES_PASSWORD, OIDC_* vars)
  #
  # Also create /var/lib/krg/krg-prod/.env with:
  #   USER_ID=<UID of the account that owns the working directory>
  #   GROUP_ID=<GID of the account that owns the working directory>
  krg.composeStacks.krg-prod = {
    description      = "KRG production (lab-wide) stack — Traefik + Authentik + Grafana + services";
    composeFiles     = [ "${composeDir}/compose.yml" ];
    workingDirectory = "/var/lib/krg/krg-prod";
    # External networks declared in compose.yml and compose.grafana.yml
    networks         = [ "traefik_proxy" "authentik" "prometheus_network" ];
  };

  # Provide the OEC installer archive path once the file is available locally.
  # krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;

  system.stateVersion = "25.11";
}
