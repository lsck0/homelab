# patch the vendored fints importer in place, from <name>.orig files extracted from the pinned image:
#   TanHandler: it catches RuntimeException, but the chipTAN image parse throws InvalidArgumentException, so a
#     text/flicker challenge crashes instead of rendering the startcode; it catches Throwable instead
#   RunImportBatched: the full fints persistence is only shown in a <pre> (easy to copy truncated) and never saved;
#     it is also written to a file, so a headless config can reuse it

const PERSISTENCE_DUMP = "@file_put_contents('/app/configurations/last-persistence.txt', base64_encode($session->get('persistedFints')));\n        "

# idempotent: a source the image already patched passes through
def patch [dir: path, name: string, find: string, replacement: string]: nothing -> nothing {
    let source = open --raw ($dir | path join $"($name).orig")
    let patched = if ($source | str contains $replacement) { $source } else {
        if not ($source | str contains $find) { error make {msg: $"($name): anchor not found"} }
        $source | str replace $find $replacement
    }
    $patched | save --force ($dir | path join $name)
}

def main [dir: path]: nothing -> nothing {
    patch $dir TanHandler.php 'catch (\RuntimeException' 'catch (\Throwable'
    patch $dir RunImportBatched.php '$session->invalidate();' $"($PERSISTENCE_DUMP)$session->invalidate\();"
}
