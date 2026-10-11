# where a file lives: every file has one owner, and it lives in that owner's folder
#
# Owners: an instance (src/instances/<folder>/), an app (src/apps/<name>/), a module (src/modules/<name>.nix or
# src/modules/<name>/) and the lab itself (the flake, src/scripts, src/terraform, src/secrets, src/generated, src/lab,
# src/tests, src/apps/swarm.nix, sync.sh). A file's users are the owners of the code that names it: a path literal in
# a .nix file, "$SRC/<path>" in a shell script, "${local.src}/<path>" in terraform, resolved against the file's
# directory; comment lines name what they describe without using it. Tests (anything under a tests/ folder), laws,
# docs and skills never make a file shared: a test lives with what it tests. A module counts as used by whoever uses
# the module, so the users of a file are, in the end, instances, apps or the lab.
#
# Laws:
#   - src/ holds flake.nix, flake.lock and the folders above, nothing else (no src/services, no loose data files)
#   - a module, or a file in a module folder its module does not use, that one instance or app alone uses belongs in
#     that folder's lib/; a module nothing uses goes
#   - a file in an instance folder that code outside the folder names is shared: it belongs in src/modules
#   - src/scripts holds the workstation's tools: a script that nix code names runs on a host, and one that serves a
#     single instance belongs in its folder
#   - a test lives with what it tests: one in an owner's tests/ that names files of exactly one other owner belongs
#     there, and an instance's test may run another's host but never tests its lib/; a test's own files sit beside
#     the test that names them; every test in src/tests says why it is lab-wide in its first lines (`# lab-wide: <why>`)
#   - an instance folder holds main.nix and instance.nix, a module folder default.nix, lib/ and tests/ only
{ lib, src, ... }:
let
  # -------------------------------------------------------------------------------------------------------------
  # CONSTANTS
  # -------------------------------------------------------------------------------------------------------------

  topAllowed = [ "flake.nix" "flake.lock" "apps" "generated" "instances" "lab" "modules" "scripts" "secrets" "terraform" "tests" ];
  moduleFolderAllowed = [ "default.nix" "lib" "tests" ];
  # src/tests: the harness folders beside the lab-wide tests
  harnessDirs = [ "lib" "policy" "stubs" ];
  # what the scripts write, read by name: no code to scan below
  generatedDir = "generated";
  # in the flake's source only when it is evaluated from git; a path: flake holds src alone
  syncScript = "../sync.sh";
  # folders starting with this are documentation (the templates), never an owner
  hiddenPrefix = "_";
  # the stand-ins every test shares, no test itself
  sharedStubs = "stubs.nix";
  labWideMark = "# lab-wide: ";
  # how far a lab-wide test's first lines are read for its reason (a shell test starts with its shebang)
  labWideLines = 3;
  codeSuffixes = [ ".nix" ".sh" ".tf" ];
  # a nix path literal: ./x or ../x, not inside another path or a word
  nixPathPattern = "(^|[^A-Za-z0-9_./~$-])(\\.\\.?(/[A-Za-z0-9._+-]+)+)";
  shellPathPattern = "[$]SRC\"?/([A-Za-z0-9._/+-]+)";
  terraformPathPattern = "[$][{]local[.]src[}]/([A-Za-z0-9._/+-]+)";

  # -------------------------------------------------------------------------------------------------------------
  # INTERNAL: paths relative to src/, "a/b/c"
  # -------------------------------------------------------------------------------------------------------------

  isHidden = name: lib.hasPrefix "." name || lib.hasPrefix hiddenPrefix name || name == "__pycache__";
  # every file below a directory of src/
  filesBelow = dir: lib.concatLists (lib.mapAttrsToList (name: kind:
    if isHidden name then [ ]
    else if kind == "directory" then filesBelow "${dir}/${name}"
    else lib.optional (kind == "regular") "${dir}/${name}"
  ) (builtins.readDir (src + "/${dir}")));
  entriesOf = dir: lib.attrNames (lib.filterAttrs (name: _: !(isHidden name)) (builtins.readDir (src + "/${dir}")));

  # "a/b/../c" -> "a/c"; null when it leaves src/
  normalize = path: let
    step = acc: segment:
      if acc == null || segment == "." || segment == "" then acc
      else if segment == ".." then (if acc == [ ] then null else lib.init acc)
      else acc ++ [ segment ];
    segments = lib.foldl' step [ ] (lib.splitString "/" path);
  in if segments == null then null else lib.concatStringsSep "/" segments;
  dirOfPath = path: let parts = lib.splitString "/" path; in lib.concatStringsSep "/" (lib.init parts);

  isTest = path: lib.hasPrefix "tests/" path || lib.hasInfix "/tests/" path;
  ownerOf = path: let
    instance = builtins.match "instances/([^/]+)(/.*)?" path;
    app = builtins.match "apps/([^/]+)/.*" path;
    module = builtins.match "modules/([^/.]+)(\\.nix|/.*)?" path;
  in
    if instance != null then "instances/${lib.head instance}"
    else if app != null then "apps/${lib.head app}"
    else if module != null then "modules/${lib.head module}"
    else "lab";
  kindOf = owner: lib.head (lib.splitString "/" owner);

  # -------------------------------------------------------------------------------------------------------------
  # READERS: every code file, what it names
  # -------------------------------------------------------------------------------------------------------------

  codeOf = path: lib.concatStringsSep "\n" (lib.filter (line: builtins.match "[[:space:]]*(#|//).*" line == null)
    (lib.splitString "\n" (builtins.readFile (src + "/${path}"))));
  matchesOf = pattern: group: text: map (m: lib.elemAt m group) (lib.filter lib.isList (builtins.split pattern text));
  refsOf = path: let text = codeOf path; dir = dirOfPath path; in lib.filter (t: t != null) (
    if lib.hasSuffix ".nix" path then map (p: normalize "${dir}/${p}") (matchesOf nixPathPattern 1 text)
    else if lib.hasSuffix ".sh" path then map normalize (matchesOf shellPathPattern 0 text)
    else map normalize (matchesOf terraformPathPattern 0 text));

  allFiles = lib.concatMap (entry:
    if entry == generatedDir then [ ]
    else if (builtins.readDir src).${entry} == "directory" then filesBelow entry
    else [ entry ]) (entriesOf ".");
  readerPaths = lib.filter (path: lib.any (suffix: lib.hasSuffix suffix path) codeSuffixes) allFiles
    ++ lib.optional (builtins.pathExists (src + "/${syncScript}")) syncScript;
  # a reference to a whole tree of owners (the flake discovering every folder) is no use of any of them
  discoveryRoots = [ "" "apps" "instances" "modules" "tests" ];
  readers = map (path: {
    inherit path;
    owner = ownerOf path;
    test = isTest path;
    refs = lib.filter (t: !(lib.elem t discoveryRoots)) (refsOf path);
  }) readerPaths;
  users = lib.filter (r: !r.test) readers;

  # a reader names a file when one of its targets is the file or a folder holding it
  names = r: path: lib.any (t: t == path || lib.hasPrefix "${t}/" path) r.refs;
  directUsersOf = path: lib.unique (map (r: r.owner) (lib.filter (r: names r path) users));

  # owner -> the owners naming any of its files from outside
  edges = lib.concatMap (r: map (t: { from = r.owner; to = ownerOf t; }) r.refs) users;
  ownerUsers = owner: lib.unique (map (e: e.from) (lib.filter (e: e.to == owner && e.from != owner) edges));
  # the instances, apps and "lab" a set of owners comes down to: a module stands for whoever uses it
  resolve = seen: owners: lib.unique (lib.concatMap (o:
    if kindOf o != "modules" then [ o ]
    else if lib.elem o seen then [ ]
    else resolve (seen ++ [ o ]) (ownerUsers o)) owners);
  finalUsersOf = owners: resolve [ ] owners;
  single = owners: lib.length owners == 1 && lib.head owners != "lab";

  # -------------------------------------------------------------------------------------------------------------
  # LAWS
  # -------------------------------------------------------------------------------------------------------------

  topLaws = map (name: "src/${name} is no place for a file: it belongs to an instance, a module or one of the lab's folders")
    (lib.filter (name: !(lib.elem name topAllowed)) (lib.attrNames (builtins.readDir src)));

  modules = lib.unique (map ownerOf (map (name: "modules/${name}") (entriesOf "modules")));
  moduleLaws = lib.concatMap (m: let final = finalUsersOf (ownerUsers m); in
    lib.optional (final == [ ]) "src/${m} is used by nothing: delete it"
    ++ lib.optional (single final) "src/${m} is used by ${lib.head final} alone: move it into src/${lib.head final}/lib/"
  ) modules;

  moduleFiles = lib.filter (path: lib.hasPrefix "modules/" path && !(isTest path)
    && builtins.match "modules/[^/]+(\\.nix|/default\\.nix)" path == null) allFiles;
  moduleFileLaws = lib.concatMap (path: let
    direct = directUsersOf path;
    final = finalUsersOf (lib.remove (ownerOf path) direct);
  in
    lib.optional (direct == [ ]) "src/${path} is used by nothing: delete it"
    ++ lib.optional (!(lib.elem (ownerOf path) direct) && single final)
      "src/${path} is used by ${lib.head final} alone: move it into src/${lib.head final}/lib/"
  ) moduleFiles;

  folderFiles = lib.filter (path: lib.elem (kindOf (ownerOf path)) [ "instances" "apps" ] && !(isTest path)) allFiles;
  sharedInFolderLaws = lib.concatMap (path: let outside = lib.remove (ownerOf path) (directUsersOf path); in
    lib.optional (outside != [ ]) "src/${path} is named by ${toString outside}: a file two owners use is a module (src/modules)"
  ) folderFiles;

  scripts = lib.filter (path: lib.hasPrefix "scripts/" path && !(lib.hasPrefix "scripts/lib/" path)) allFiles;
  scriptLaws = lib.concatMap (path: let
    nixUsers = lib.filter (r: lib.hasSuffix ".nix" r.path && names r path) users;
    targets = lib.unique (lib.filter (o: o != "lab") (map ownerOf (lib.concatMap (r: r.refs) (lib.filter (r: r.path == path) readers))));
  in
    map (r: "src/${path} runs on a host (${r.path} deploys it): it belongs to that module or instance") nixUsers
    ++ lib.optional (lib.length targets == 1 && kindOf (lib.head targets) == "instances")
      "src/${path} serves ${lib.head targets} alone: move it into src/${lib.head targets}/lib/"
  ) scripts;

  # tests: src/tests/<file>, or <owner>/tests/<file>
  testFiles = lib.filter isTest allFiles;
  testDirOf = path: dirOfPath path;
  namedBeside = path: lib.any (r: r.path != path && testDirOf r.path == testDirOf path && lib.elem path r.refs) readers;
  # a test runnable by hand (media-stack.sh): it starts with its interpreter
  isScript = path: lib.hasPrefix "#!" (builtins.readFile (src + "/${path}"));
  instanceFolders = lib.filter (f: (builtins.readDir (src + "/instances")).${f} == "directory") (entriesOf "instances");
  # a test reaches its host by path or by configuration name (inputs.self.nixosConfigurations."<folder>")
  # an instance's or app's own code (a script, a template): a test of another owner may run its host, never test it
  libOfFolder = path: builtins.match "(instances|apps)/[^/]+/lib/.+" path != null;
  hostsNamedIn = path: map (f: "instances/${f}") (lib.filter (f: lib.hasInfix "\"${f}\"" (codeOf path)) instanceFolders);
  labWideLaws = lib.concatMap (path: let head = lib.take labWideLines (lib.splitString "\n" (builtins.readFile (src + "/${path}"))); in
    lib.optional (path != "tests/${sharedStubs}" && !(namedBeside path) && !(lib.any (lib.hasPrefix labWideMark) head))
      "src/${path} is in src/tests without `${labWideMark}<why>` in its first lines: a test of one owner lives in its tests/"
  ) (lib.filter (path: testDirOf path == "tests") testFiles)
  ++ map (dir: "src/tests/${dir}: src/tests holds the harness (${toString harnessDirs}) and lab-wide tests only")
    (lib.filter (e: (builtins.readDir (src + "/tests")).${e} == "directory" && !(lib.elem e harnessDirs)) (entriesOf "tests"));
  ownTestLaws = lib.concatMap (path: let
    owner = ownerOf path;
    r = lib.findFirst (r: r.path == path) null readers;
    targets = lib.unique (lib.filter (o: o != "lab") (map ownerOf (lib.filter (t: !(isTest t)) r.refs)));
    reached = targets ++ hostsNamedIn path;
  in
    lib.optional (!(lib.hasSuffix ".nix" path) && !(namedBeside path) && !(isScript path))
      "src/${path} is named by no test beside it: it belongs beside the test that runs it"
    ++ lib.optional (r != null && lib.hasSuffix ".nix" path && !(lib.elem owner reached) && lib.length targets == 1)
      "src/${path} tests ${lib.head targets} alone: move it into src/${lib.head targets}/tests/"
    ++ map (t: "src/${path} tests ${t}: its cases belong in src/${ownerOf t}/tests/")
      (lib.filter (t: kindOf owner == "instances" && ownerOf t != owner && libOfFolder t)
        (lib.optionals (r != null) r.refs))
  ) (lib.filter (path: ownerOf path != "lab" && builtins.match "[^/]+/[^/]+/tests/[^/]+" path != null) testFiles);

  folderLaws = lib.concatMap (folder: let files = builtins.readDir (src + "/instances/${folder}"); in
    map (f: "src/instances/${folder} has no ${f}") (lib.filter (f: !(files ? ${f})) [ "main.nix" "instance.nix" ])
  ) instanceFolders
  ++ lib.concatMap (folder: let entries = entriesOf "modules/${folder}"; in
    lib.optional (!(lib.elem "default.nix" entries)) "src/modules/${folder} has no default.nix"
    ++ map (e: "src/modules/${folder}/${e}: a module folder holds default.nix, lib/ and tests/ only")
      (lib.filter (e: !(lib.elem e moduleFolderAllowed)) entries)
  ) (lib.filter (f: (builtins.readDir (src + "/modules")).${f} == "directory") (entriesOf "modules"));
in
topLaws ++ moduleLaws ++ moduleFileLaws ++ sharedInFolderLaws ++ scriptLaws ++ labWideLaws ++ ownTestLaws ++ folderLaws
