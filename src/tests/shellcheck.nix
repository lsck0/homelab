# lab-wide: every shell script of the repo
# every shell script of the repo passes shellcheck at its strictest default (style notes included): sync.sh, the
# hook, every *.sh under src, and the shell embedded in nix: the bodies of writeShellScript, writeShellScriptBin and
# writeShellApplication and the systemd `script`, `preStart`, `postStart`, `preStop` and `postStop` strings. A
# disabled check carries its reason in a directive next to the code.
#
# An embedded body is read from `nix-instantiate --parse`, which has already stripped the indentation and resolved
# the escapes; each antiquotation becomes the word __NIX__. Its file is bodies/<nix file>.<attribute>-<n>.sh, line 1
# the shebang, so its line N is line N - 1 of the string. A body behind a function call (lib.mkAfter "...") is
# not reached. An antiquotation hides what it expands to, so three checks cannot judge a body and are off for bodies
# alone: SC1091 (a sourced store path), SC2043 (a loop over a nix list) and SC2154 (a variable the unit's environment
# or nix-rendered code sets).
#
# sync.sh and the hook live at the repo's top, which only a git flake (git+file:...?dir=src) holds; a path: flake
# holds src alone, and this check refuses it instead of passing on part of the repo.
{ pkgs, lib, ... }:
let
  repo = ../..;
  wholeRepo = builtins.pathExists (repo + "/sync.sh");
  scripts = lib.fileset.toSource {
    root = repo;
    fileset = lib.fileset.unions [
      (repo + "/sync.sh")
      (repo + "/.githooks")
      (lib.fileset.fileFilter (f: f.hasExt "sh") ../.)
    ];
  };
  nixFiles = lib.fileset.toSource { root = ../.; fileset = lib.fileset.fileFilter (f: f.hasExt "nix") ../.; };

  extract = pkgs.writeText "shellcheck-bodies.py" ''
    """the shell bodies of `nix-instantiate --parse` outputs: extract.py <parsed dir> <out dir>, one parsed file per
    nix file at its own relative path"""
    import re
    import sys
    from pathlib import Path

    BODY_ATTRS = ("script", "preStart", "postStart", "preStop", "postStop")
    NAMED_WRITERS = ("writeShellScript", "writeShellScriptBin")
    APPLICATION_WRITER = "writeShellApplication"
    PLACEHOLDER = "__NIX__"
    SHEBANG = "#!/usr/bin/env bash\n"
    ESCAPES = {"n": "\n", "t": "\t", "r": "\r"}
    PUNCTUATION = "(){}[];,"
    OPERATOR = re.compile(r"[-+*/<>=!&|?:@]+")


    def tokens_read(text):
        """("str", value) for a string literal, ("op", s) or ("word", s) for the rest."""
        out, i = [], 0
        while i < len(text):
            c = text[i]
            if c.isspace():
                i += 1
            elif c == '"':
                value, i = [], i + 1
                while text[i] != '"':
                    if text[i] == "\\":
                        value.append(ESCAPES.get(text[i + 1], text[i + 1]))
                        i += 2
                    else:
                        value.append(text[i])
                        i += 1
                out.append(("str", "".join(value)))
                i += 1
            elif c in PUNCTUATION:
                out.append(("op", c))
                i += 1
            elif (m := OPERATOR.match(text, i)) and not text.startswith("/nix", i):
                out.append(("op", m.group()))
                i = m.end()
            else:
                j = i
                while j < len(text) and not text[j].isspace() and text[j] not in PUNCTUATION + '"':
                    j += 1
                out.append(("word", text[i:j]))
                i = j
        return out


    def group_end(toks, i):
        """the index after the bracket that closes the one at i."""
        depth = 0
        for j in range(i, len(toks)):
            if toks[j][0] == "op" and toks[j][1] in "([{":
                depth += 1
            elif toks[j][0] == "op" and toks[j][1] in ")]}":
                depth -= 1
                if depth == 0:
                    return j + 1
        raise ValueError("unbalanced brackets")


    def body_render(toks, i):
        """the shell text of the expression at i: a string, or a parenthesised `+` concatenation; None otherwise."""
        kind, value = toks[i]
        if kind == "str":
            return value
        if (kind, value) != ("op", "("):
            return None
        end, parts, item = group_end(toks, i) - 1, [], []
        j = i + 1
        while j <= end:
            if j == end or toks[j] == ("op", "+"):
                rendered = body_render(toks, item[0]) if len(item) == 1 else None
                parts.append(PLACEHOLDER if rendered is None else rendered)
                item = []
                j += 1
            elif toks[j][0] == "op" and toks[j][1] in "([{":
                item.append(j)
                j = group_end(toks, j)
            else:
                item.append(j)
                j += 1
        return "".join(parts)


    def last_name(word):
        return word.rsplit(".", 1)[-1]


    def bodies_find(toks):
        """(attribute, body start index) of every shell body."""
        for i, (kind, value) in enumerate(toks[:-2]):
            if kind != "word":
                continue
            name = last_name(value)
            if name in BODY_ATTRS and toks[i + 1] == ("op", "="):
                yield name, i + 2
            elif name in NAMED_WRITERS and toks[i + 1][0] == "str":
                yield f"{name}-{toks[i + 1][1]}", i + 2
            elif name == APPLICATION_WRITER and toks[i + 1] == ("op", "{"):
                end = group_end(toks, i + 1)
                depth = 0
                for j in range(i + 1, end - 1):
                    if toks[j][0] == "op" and toks[j][1] in "([{":
                        depth += 1
                    elif toks[j][0] == "op" and toks[j][1] in ")]}":
                        depth -= 1
                    elif depth == 1 and toks[j] == ("word", "text") and toks[j + 1] == ("op", "="):
                        yield APPLICATION_WRITER, j + 2


    def main():
        parsed_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
        for parsed in sorted(parsed_dir.rglob("*.nix")):
            name = parsed.relative_to(parsed_dir)
            toks = tokens_read(parsed.read_text())
            for n, (attr, start) in enumerate(bodies_find(toks)):
                body = body_render(toks, start)
                if body is None or not body.replace(PLACEHOLDER, "").strip():
                    continue
                target = out / f"{name}.{attr}-{n}.sh"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(SHEBANG + body)


    main()
  '';
in
assert lib.assertMsg wholeRepo
  "shellcheck needs the whole repo (sync.sh, .githooks): build it from git, `nix build ./src#checks.x86_64-linux.shellcheck`, not from a path: flake";
pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck pkgs.findutils pkgs.nix pkgs.python3 ]; } ''
  export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/nix
  mkdir tree && cd tree
  cp -r ${scripts}/. .
  chmod -R u+w .
  (cd ${nixFiles} && find . -name '*.nix' -printf '%P\n') | while read -r f; do
    mkdir -p "$TMPDIR/parsed/$(dirname "$f")"
    nix-instantiate --store dummy:// --parse "${nixFiles}/$f" > "$TMPDIR/parsed/$f"
  done
  python3 ${extract} "$TMPDIR/parsed" bodies
  # -x follows the sourced libraries, whose paths the `source=` directives give relative to the repo root
  find . -path ./bodies -prune -o -type f \( -name '*.sh' -o -path './.githooks/*' \) -print0 | sort -z | xargs -0 shellcheck -x
  find bodies -type f -print0 | sort -z | xargs -0 shellcheck -e SC1091,SC2043,SC2154
  echo "shellcheck: $(find . -type f \( -name '*.sh' -o -path './.githooks/*' \) | wc -l) scripts clean, $(find bodies -type f | wc -l) of them embedded in nix"
  touch $out
''
