# bcrypt htpasswd files from sops secrets, each password read from its file on stdin, never from an argv: the
# ingress's basic auth (modules/traefik) and every backend checking the same users again (118's registry)
#
#   htpasswd = import ../modules/traefik/lib/htpasswd.nix { inherit pkgs lib; };
#   script = htpasswd.render "/run/x/users" { ci = config.sops.secrets.registry-push-password.path; };
{ pkgs, lib }: {
  # shell lines writing the file whole: a reader never sees half of it
  render = file: users: ''
    : > ${file}.tmp
  '' + lib.concatStrings (lib.mapAttrsToList (user: path: ''
    ${pkgs.apacheHttpd}/bin/htpasswd -niB ${user} < ${path} >> ${file}.tmp
  '') users) + ''
    mv ${file}.tmp ${file}
  '';
}
