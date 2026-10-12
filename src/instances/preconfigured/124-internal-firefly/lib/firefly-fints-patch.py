#!/usr/bin/env python3
# patch the vendored fints importer in place (files extracted from the pinned image):
#  - TanHandler: it catches RuntimeException, but the chipTAN image parse throws
#    InvalidArgumentException, so a text/flicker challenge crashes instead of rendering
#    the startcode. catch Throwable instead.
#  - RunImportBatched: the full fints persistence is only shown in a <pre> (easy to copy
#    truncated) and never saved. also write it to a file so a headless config can reuse it.
import sys

d = sys.argv[1]


def patch(name, find, repl, count=1):
    src = open(f"{d}/{name}.orig").read()
    if repl in src:
        out = src
    else:
        assert find in src, f"{name}: anchor not found"
        out = src.replace(find, repl, count)
    open(f"{d}/{name}", "w").write(out)


patch("TanHandler.php", r"catch (\RuntimeException", r"catch (\Throwable")

dump = (
    "@file_put_contents('/app/configurations/last-persistence.txt', "
    "base64_encode($session->get('persistedFints')));\n        "
)
patch("RunImportBatched.php", "$session->invalidate();", dump + "$session->invalidate();")
