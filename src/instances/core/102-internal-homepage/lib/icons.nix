# the dashboard's icons, served by homepage itself: it resolves a bare name (dashboard-icons) and `mdi-<name>`
# (Material Design Icons) from jsDelivr in the visitor's browser, so each is fetched here once, pinned by hash.
#
#   src icon        what the yaml names: the icon's path under homepage's own public directory
#   dir icons       the directory of every named icon, mounted there
#
# A new dashboard icon needs its hash below: add `<name> = "";`, build vm-102, paste the hash nix reports.
{ lib, pkgs }:
let

  publicPath = "/icons";
  dashboardIconsRev = "104a791794ef68b31bfecac676ddace8c223fd27";
  mdiVersion = "7.4.47";
  mdiPrefix = "mdi-";
  # homepage's iconStyle theme paints an mdi icon in its color's 300 shade; slate-300, the theme's color
  mdiColor = "#cbd5e1";

  mdi = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@mdi/svg/-/svg-${mdiVersion}.tgz";
    hash = "sha512-WQ2gDll12T9WD34fdRFgQVgO8bag3gavrAgJ0frN4phlwdJARpE6gO1YvLEMJR0KKgoc+/Ea/A0Pp11I00xBvw==";
  };

  # dashboard-icons' png/<name>.png at dashboardIconsRev
  hashes = {
    arch-linux = "sha256-yf0Fi2+O9F3X/EUdKlo1CGWaFQoVDN/lA0f1h5xuC7Y=";
    authelia = "sha256-zt8ljDf2kRrtjBeNWOhQ80LLrWY21NvXZ7g01mf/i04=";
    bazarr = "sha256-UnzDBbVWV+odsX3p2WK+ZhGgmz8ZcrEltoo+s7FSnkU=";
    cloudflare = "sha256-jytAItZ4EQJf7HG0DzY+KzuCh983FNjp7soApapeBJA=";
    docker = "sha256-UxXzbCXVToGaR5t2Vcn4g8cnx02TT9PM7MuUGfW6Jr0=";
    docker-moby = "sha256-tmHnvmXZE3R20wKbjXP8nlTICTM+dkSjMbY36fk4Luo=";
    firefly-iii = "sha256-FWxgUrKbMp0Xy6jzfbHR+2TrZydtBZGQWjue7PII0nM=";
    forgejo = "sha256-eMuO1tKZdjfiMLY2tQrccPxwlox2slyQcO0Uxsg34+k=";
    grafana = "sha256-41JjeXIHjGsu1zlZkqCLAC8gsvulIvPDS8UpRrJ0ddg=";
    headscale = "sha256-MVz9ygwsbaooMLkYsp2iJV7PlpXzSATKfjUkswxST20=";
    home-assistant = "sha256-ZYL/8I23W1+xHVEzFFocAJ1fodaUB4kzCmOPI06FLL4=";
    huginn = "sha256-SOyQGRUQ4vH1c7s0TT3vMzdE2u9HvApgyDUdvQLk4dM=";
    jellyfin = "sha256-LkXHuwSx/bxwc3vhZ2xzvPvpjc2fctzQYxlscHXGWzc=";
    jellyseerr = "sha256-0+XlBYo+XJJBB2kURdkdep2KCcunAD3rh8PAgAZziwc=";
    kopia = "sha256-DJBRQGjCSW8bK7Jh7KkvD2w/RfReOk77uyMzNHe5Qco=";
    lidarr = "sha256-ZwXNAEV/4pXRnKCwhlTPgn9eIHB0/H5MgYKm1crmW3w=";
    navidrome = "sha256-23Tyd/rNrBTAFhrUvNgMOOXQl4Wotsk8ILp4BoeafKk=";
    nixos = "sha256-IM+VMjejwv0CJ5MMixAWXPHL9aNMwx+K4Nfy1opXOHY=";
    ntfy = "sha256-eHqBHmPXPz7tJGfsMG4WlER4zsrmL2vIovP2V3S9vJg=";
    paperless-ngx = "sha256-SsoON0XD9jCsXod5dNQzwoPan9xKQEyFsLyEQci5BLI=";
    pingvin-share = "sha256-eBnbHFp6A7rWSyp7WvV3v+IOD64Oyl1s1YnvPwCXw+I=";
    privatebin = "sha256-mkf4z+m1rOfpQNBHYtNR4qm63H+cvSqGrDPZTWtF/og=";
    prowlarr = "sha256-cPzVvWQr/mWTbkdGlJfeY4773rjTDqkW/ff5x0PX6Qg=";
    proxmox = "sha256-D8U9N7ZoXBr1AY+jfRXvAqFog2Yc79aPbGImTd8r34s=";
    qbittorrent = "sha256-PQOiyRRAqFq2h5IH+Q4XqP+clYCuWibsOmSywkGPcBk=";
    radarr = "sha256-LRU0+HUT4qejtpllTf7SunD29laT7UoBXklzFRNeLmc=";
    searxng = "sha256-JSqkJsrNqcmYGJQeu4bJeDjNV5VSU5EBLnJNqxZ1Kp0=";
    sonarr = "sha256-ptMoPQIytaC9BXLz0m7cvmTQfTb0PD/CjU8LwVXq9Jo=";
    syncthing = "sha256-+0YVUfht3omTKNMCt7C886IUR9jDtWeQDJb6HRHEPPI=";
    traefik = "sha256-z/eLNq/Za+pYksebj0gMn7JSSsNDAHoLzz9WHogUa1s=";
  };

  isMdi = lib.hasPrefix mdiPrefix;
  fileOf = icon: if isMdi icon then "${icon}.svg" else "${icon}.png";
  dashboardIcon =
    icon:
    pkgs.fetchurl {
      name = fileOf icon;
      url = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/${dashboardIconsRev}/png/${icon}.png";
      hash = hashes.${icon};
    };
in
{
  src = icon: "${publicPath}/${fileOf icon}";

  dir =
    icons:
    let
      mdiIcons = lib.filter isMdi icons;
      dashboardIcons = lib.subtractLists mdiIcons icons;
      unpinned = lib.filter (icon: !(hashes ? ${icon})) dashboardIcons;
    in
    assert lib.assertMsg (
      unpinned == [ ]
    ) "102-internal-homepage: no pinned hash for the icons ${toString unpinned} (lib/icons.nix)";
    pkgs.runCommand "homepage-icons" { } ''
      mkdir -p $out
      tar -xzf ${mdi} --strip-components=2 -C $TMPDIR package/svg
      for icon in ${lib.escapeShellArgs (map (lib.removePrefix mdiPrefix) mdiIcons)}; do
        sed 's|<svg |<svg fill="${mdiColor}" |' "$TMPDIR/$icon.svg" > "$out/${mdiPrefix}$icon.svg"
      done
      ${lib.concatMapStrings (icon: "cp ${dashboardIcon icon} $out/${fileOf icon}\n") dashboardIcons}
    '';

  inherit publicPath;
}
