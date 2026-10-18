#!/usr/bin/env -S nu --no-config-file
# print a 1h github app installation token for one repo

const API_URL = "https://api.github.com"
const API_VERSION = "2022-11-28"
# github accepts an app jwt for at most 10 minutes; iat is backdated for clock skew
const JWT_BACKDATE_S = 60
const JWT_LIFETIME_S = 540

def b64url []: any -> string {
    encode base64 --url --nopad
}

def jwt-create [app_id: string, key: path]: nothing -> string {
    let now = date now | into int | $in // 1_000_000_000
    let header = {alg: RS256, typ: JWT} | to json --raw | b64url
    let payload = {iat: ($now - $JWT_BACKDATE_S), exp: ($now + $JWT_LIFETIME_S), iss: $app_id} | to json --raw | b64url
    # complete: on nu 0.108 a failing external piped on yields an empty signature instead of an error
    let signed = $"($header).($payload)" | ^openssl dgst -sha256 -sign $key -binary | complete
    if $signed.exit_code != 0 {
        print -e $"github-app-token: openssl cannot sign with ($key): ($signed.stderr | str trim)"
        exit 1
    }
    $"($header).($payload).($signed.stdout | b64url)"
}

def main [app_id: string, key: path, repo: string]: nothing -> nothing {
    let headers = {Authorization: $"Bearer (jwt-create $app_id $key)", Accept: "application/vnd.github+json", X-GitHub-Api-Version: $API_VERSION}
    let installation = try { http get --headers $headers $"($API_URL)/repos/($repo)/installation" | get id } catch {
        print -e $"github-app-token: app ($app_id) is not installed on ($repo)"
        exit 1
    }
    let name = $repo | split row "/" | last
    let token = http post --headers $headers --content-type application/json $"($API_URL)/app/installations/($installation)/access_tokens" {repositories: [$name]}
    print $token.token
}
