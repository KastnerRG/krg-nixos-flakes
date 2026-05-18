# Fabricant server user accounts (from fabricant-prod create_users.yaml)
{ ... }: {
  users.groups.services = {};

  krg.users.users = {
    fabricant-admin = {
      description    = "Fabricant deployment administrator";
      groups         = [ "docker" "wheel" "services" ];
      sudoNoPassword = true;
      authorizedKeys = [
        # Add fabricant-admin SSH public key here
      ];
    };

    # Service accounts used by Docker Compose stacks
    # (from web_services.yaml: fs_services and sf_services in docker + services groups)
    fs-services = {
      description = "Frontend services account";
      groups      = [ "docker" "services" ];
      authorizedKeys = [];
    };

    sf-services = {
      description = "Backend services account";
      groups      = [ "docker" "services" ];
      authorizedKeys = [];
    };
  };
}
