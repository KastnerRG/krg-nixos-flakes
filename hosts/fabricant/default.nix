{ ... }:
let
  # Referencing the directory (not individual files) ensures Docker Compose
  # `include:` directives can resolve sibling compose files from the same
  # Nix store path, and lets us symlink config subdirs from the working dir.
  composeDir = ../../docker-compose/fabricant;
in {
  imports = [
    ../../profiles/server.nix
    ./hardware-configuration.nix
  ];

  networking = {
    hostName = "fabricant";
    domain   = "ucsd.edu";
  };

  # label_studio_admin group (from fabricant-prod label_studio.yaml)
  users.groups.label_studio_admin = {};

  systemd.tmpfiles.rules = [
    # ── Shared host storage ───────────────────────────────────────────────
    # Shared Label Studio file storage; mounted into the container as /data
    "d /share/label-studio/files 0777 root root -"

    # ── Working directory layout under /var/lib/krg/fabricant/ ───────────
    # (the compose-stack module already creates /var/lib/krg/fabricant/ and .secrets/)

    # Read-only config dirs: symlink from working dir → Nix store.
    # Docker bind-mount follows symlinks so ./prometheus resolves to the store path.
    "L /var/lib/krg/fabricant/prometheus          - - - - ${composeDir}/prometheus"
    "L /var/lib/krg/fabricant/blackbox-exporter   - - - - ${composeDir}/blackbox-exporter"
    "L /var/lib/krg/fabricant/grafana             - - - - ${composeDir}/grafana"

    # Loki: separate read-only config files from writable data dir
    "d  /var/lib/krg/fabricant/loki                          0750 1000 1000 -"
    "L  /var/lib/krg/fabricant/loki/loki-config.yaml         - - - - ${composeDir}/loki/loki-config.yaml"
    "L  /var/lib/krg/fabricant/loki/promtail-config.yaml     - - - - ${composeDir}/loki/promtail-config.yaml"
    "d  /var/lib/krg/fabricant/loki/loki-data                0750 1000 1000 -"

    # Label-studio postgres: config (read-only symlinks) + data (writable)
    "d  /var/lib/krg/fabricant/postgres                      0750 root   docker -"
    "L  /var/lib/krg/fabricant/postgres/config               - - - - ${composeDir}/postgres/config"
    "L  /var/lib/krg/fabricant/postgres/scripts              - - - - ${composeDir}/postgres/scripts"
    "d  /var/lib/krg/fabricant/postgres/data                 0750 1000 1000 -"

    # Authentik postgres: same pattern
    "d  /var/lib/krg/fabricant/authentik                     0750 root   docker -"
    "d  /var/lib/krg/fabricant/authentik/postgres            0750 root   docker -"
    "L  /var/lib/krg/fabricant/authentik/postgres/config     - - - - ${composeDir}/authentik/postgres/config"
    "L  /var/lib/krg/fabricant/authentik/postgres/scripts    - - - - ${composeDir}/authentik/postgres/scripts"
    "d  /var/lib/krg/fabricant/authentik/postgres/data       0750 1000 1000 -"
    "d  /var/lib/krg/fabricant/authentik/media               0750 1000 1000 -"
    "d  /var/lib/krg/fabricant/authentik/data                0750 1000 1000 -"
    "d  /var/lib/krg/fabricant/authentik/certs               0750 1000 1000 -"
    "d  /var/lib/krg/fabricant/authentik/custom-templates    0750 1000 1000 -"
    "d  /var/lib/krg/fabricant/authentik/proxy-tmp           0750 root  root -"

    # Outline: docker.env is read-only; data dirs are writable
    "d  /var/lib/krg/fabricant/outline                       0750 root   docker -"
    "L  /var/lib/krg/fabricant/outline/docker.env            - - - - ${composeDir}/outline/docker.env"
    "d  /var/lib/krg/fabricant/outline/outline_data          0750 1000 1000 -"
    "d  /var/lib/krg/fabricant/outline/postgres              0750 1000 1000 -"

    # MLflow: no config files in repo; init-db.sql must be added when available
    "d  /var/lib/krg/fabricant/mlflow                        0750 root   docker -"

    # Grafana, Prometheus data (writable)
    "d  /var/lib/krg/fabricant/grafana-storage               0750 1000 1000 -"
    "d  /var/lib/krg/fabricant/prometheus-data               0750 1000 1000 -"

    # Label Studio data
    "d  /var/lib/krg/fabricant/label_studio_data_pg          0750 1000 1000 -"

    # Traefik TLS certificate storage
    "d  /var/lib/krg/fabricant/traefik-data                  0750 root docker -"
    "d  /var/lib/krg/fabricant/traefik-data/letsencrypt      0750 root docker -"
  ];

  # fabricant-prod runs as a single compose project (compose.yml uses `include:`
  # to bring in authentik, grafana, label-studio, mlflow, and outline stacks).
  #
  # Secrets required in /var/lib/krg/fabricant/.secrets/ before starting:
  #   authentik_postgres_admin_password.txt
  #   authentik_admin_password.env      (AUTHENTIK_SECRET_KEY=... AUTHENTIK_POSTGRESQL__PASSWORD=...)
  #   authentik_traefik_token.env
  #   gf_admin_password.txt
  #   label_studio_admin_password_pg.env
  #   postgres_admin_password.txt       (for label-studio postgres)
  #   outline_secrets.env               (SECRET_KEY, UTILS_SECRET, OIDC_CLIENT_SECRET, DATABASE_URL, ...)
  #   mlflow.env                        (POSTGRES_PASSWORD, OIDC_* vars)
  #
  # Also create /var/lib/krg/fabricant/.env with:
  #   USER_ID=<UID of fabricant-admin user>
  #   GROUP_ID=<GID of fabricant-admin user>
  krg.composeStacks.fabricant = {
    description      = "Fabricant production stack (Traefik + Authentik + Grafana + services)";
    composeFiles     = [ "${composeDir}/compose.yml" ];
    workingDirectory = "/var/lib/krg/fabricant";
    # External networks declared in compose.yml and compose.grafana.yml
    networks         = [ "traefik_proxy" "authentik" "prometheus_network" ];
  };

  # Provide the OEC installer archive path once the file is available locally.
  # krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;
}
