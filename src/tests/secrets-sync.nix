# lab-wide: scripts/secrets-sync.sh, the workstation's secrets tool
# secrets-sync.sh in the sandbox, over plans modules/secrets.nix makes of a small fake lab: placement, isolation, kinds,
# guarded secrets, idempotence, moves, prune, hosts leaving, the admin-key rotation, atomicity under injected sops
# failures, and one run over the real plan (secrets_sync_test.sh says what each numbered assertion claims). Throwaway
# age keys, no network; `seed` draws the injected faults and the sampled pairs.
{ pkgs, lib, inputs, seed ? 1, ... }:
let
  system = pkgs.stdenv.hostPlatform.system;

  # a guest of the fake lab: a folder unless it is a swarm worker; `reads` are the sops keys its config reads
  guest = { id, name, hostName ? "vm-${id}", secrets ? { }, reads }: {
    instance = { inherit id name; dir = if lib.hasSuffix "-apps-swarm" name then null else "fixture"; config = { inherit hostName secrets; }; };
    config.sops.secrets = lib.genAttrs reads (key: { inherit key; });
  };
  planOf = { guests, catalog, apps ? { x.secrets.x-app = "garage-key-id"; } }:
    let
      layout = import ../modules/secrets.nix {
        inherit lib catalog;
        lab = {
          instances = lib.listToAttrs (map (g: lib.nameValuePair g.instance.id g.instance) guests);
          hosts = lib.listToAttrs (map (g: lib.nameValuePair g.instance.name { inherit (g.instance) id; }) guests);
          appsCatalog.apps = apps;
          oidc = [ { secret = "b-oidc-secret"; } ];
        };
      };
    in builtins.toJSON (layout.planOf (lib.listToAttrs (map (g: lib.nameValuePair g.instance.name g.config) guests)));

  catalog = { shared = "hex:16"; gen = "hex:16"; tok = "ntfy-token"; pub = "public"; man = "manual"; vault = "guardsData:hex:16"; wg = "wireguard"; };
  a = own: guest { id = "100"; name = "100-internal-a"; secrets = { a-own = "hex:16"; } // own; reads = [ "a-own" "shared" "gen" ]; };
  b = reads: guest { id = "101"; name = "101-internal-b"; reads = [ "shared" "b-oidc-secret" "x-app" "app-x-redeploy-token" ] ++ reads; };
  node = guest { id = "250"; name = "250-apps-swarm"; reads = [ "shared" ]; };
  router = guest { id = "300"; name = "300-router"; hostName = "luca-router"; secrets = { r-own = "manual"; }; reads = [ "r-own" "tok" "b-oidc-secret" ]; };

  plans = pkgs.linkFarm "secrets-sync-plans" (lib.mapAttrsToList (name: text: { name = "${name}.json"; path = pkgs.writeText name text; }) {
    base = planOf { guests = [ (a { }) (b [ ]) node router ]; inherit catalog; };
    # gen: from the shared file into a's own
    moved = planOf { guests = [ (a { gen = "hex:16"; }) (b [ ]) node router ]; catalog = removeAttrs catalog [ "gen" ]; };
    # b and the worker gone: their keys and copies go, the app's file loses its reader
    minus = planOf { guests = [ (a { }) router ]; inherit catalog; };
    # man no longer declared: unused, or pruned
    unman = planOf { guests = [ (a { }) (b [ ]) node router ]; catalog = removeAttrs catalog [ "man" ]; };
    # the guarded vault renamed: a missing guarded secret after the first deploy
    renamed = planOf { guests = [ (a { }) (b [ ]) node router ]; catalog = removeAttrs catalog [ "vault" ] // { vault2 = "guardsData:hex:16"; }; };
    # b reads a secret nothing declares
    problem = planOf { guests = [ (a { }) (b [ "nope" ]) node router ]; inherit catalog; };
    real = builtins.toJSON inputs.self.legacyPackages.${system}.secrets.plan;
  });

  # only what the test runs, so an unrelated edit does not rerun it; the sandbox has no /usr/bin/env
  scripts = pkgs.runCommand "secrets-sync-scripts" { } ''
    cp -r ${lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../scripts/secrets-sync.sh ../scripts/sops-encrypt.sh
        ../scripts/lib/tools.sh ../scripts/lib/secrets.sh
      ];
    }} $out
    chmod -R u+w $out
    patchShebangs $out
  '';
in
pkgs.runCommand "secrets-sync-seed-${toString seed}" {
  nativeBuildInputs = with pkgs; [ bash sops age jq openssl git coreutils findutils diffutils gnused gnugrep ];
  passthru.regressionSeeds = [ ];
} ''
  export HOME=$TMPDIR
  bash ${./secrets_sync_test.sh} ${scripts} ${toString seed} ${plans}
  touch $out
''
