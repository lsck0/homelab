# Blackbox FULL ASSESSMENT - 192.168.178.200

_Generated 2026-09-16 01:39 by server-fucker.sh._

**Target:** `https://192.168.178.200:8006/`  
**Auth:**   
**Mode:**   
**Port scan:** top 1000  

## Executive summary

| Severity | nuclei | verified (this tool) | total |
|---|---|---|---|
| Critical | 0 | 0 | 0 |
| High | 0 | 52 | 52 |
| Medium | 0 | 0 | 0 |
| Low | 0 | 0 | 0 |
| Info | 0 | - | 0 |

_"verified" = actively confirmed by this tool (response-evidence / cross-identity / header analysis), not template matches._

Raw tool output is under `raw/`.

## Verified Active Findings

Actively confirmed by this tool via response evidence, cross-identity comparison, or token analysis (higher confidence than template scans).
**Hardcoded secrets/tokens in JS bundles:**
```
18616:password = me.lookup
18641:Secret: function
18837:password = values.password
18978:password = values.password
19235:password = values.password
2081:password: function
24228:token = extTokenizer.call
24241:token = _this.tokenizer.space
24254:token = _this.tokenizer.code
24269:token = _this.tokenizer.fences
24276:token = _this.tokenizer.heading
24283:token = _this.tokenizer.hr
24290:token = _this.tokenizer.blockquote
24297:token = _this.tokenizer.list
24304:token = _this.tokenizer.html
24311:token = _this.tokenizer.def
24328:token = _this.tokenizer.table
24335:token = _this.tokenizer.lheading
24360:token = _this.tokenizer.paragraph
24376:token = _this.tokenizer.text
24462:token = extTokenizer.call
24475:token = _this2.tokenizer.escape
24482:token = _this2.tokenizer.tag
24495:token = _this2.tokenizer.link
24502:token = _this2.tokenizer.reflink
24515:token = _this2.tokenizer.emStrong
24522:token = _this2.tokenizer.codespan
24529:token = _this2.tokenizer.br
24536:token = _this2.tokenizer.del
24543:token = _this2.tokenizer.autolink
```
_no actively-verified vulnerabilities. (Absence is not proof of safety — see template + fuzzing sections below.)_
_Tip: supply `--cookie2/--header2` (a second, lower-priv session) to unlock cross-user IDOR/BFLA confirmation._
_Tip: supply `--collab <oob-host>` to catch blind SSRF/RCE/log4shell out-of-band._

## Network Infrastructure & Routing

**Routing path:**
```
 1?: [LOCALHOST]                      pmtu 1500
 1:  192.168.178.200                                       3.545ms reached
 1:  192.168.178.200                                       1.387ms reached
     Resume: pmtu 1500 hops 1 back 1 

```
**DNS Analysis:**
```
200.178.168.192.in-addr.arpa domain name pointer luca-server.fritz.box.

```

## Attack surface - open ports & services


## HTTP Fingerprint & Security Headers

```

    __    __  __       _  __
   / /_  / /_/ /_____ | |/ /
  / __ \/ __/ __/ __ \|   /
 / / / / /_/ /_/ /_/ /   |
/_/ /_/\__/\__/ .___/_/|_|
             /_/

		projectdiscovery.io

[INF] Current httpx version v1.10.0 (outdated)
[WRN] UI Dashboard is disabled, Use -dashboard option to enable
2026/09/16 01:36:46 INFO Model not found, downloading url=https://huggingface.co/datasets/happyhackingspace/dit/resolve/main/model.json dest=/home/luca/.dit/model.json
2026/09/16 01:36:48 INFO Model downloaded size=92.6MB
[asnmap-api] missing or invalid api key (get free api key & configure it from https://cloud.projectdiscovery.io/?ref=api_key)
{"timestamp":"2026-09-16T01:36:48.98140951+02:00","port":"8006","url":"https://192.168.178.200:8006/","input":"https://192.168.178.200:8006/","title":"luca-server - Proxmox Virtual Environment","scheme":"https","webserver":"pve-api-daemon/3.0","content_type":"text/html","method":"GET","host":"192.168.178.200","host_ip":"192.168.178.200","path":"/","favicon":"213144638","favicon_md5":"908db8e56aeee8bb7a911b5df4eaf90e","favicon_path":"/pve2/images/logo-128.png","favicon_url":"https://192.168.178.200:8006/pve2/images/logo-128.png","time":"32.431565ms","jarm_hash":"2ad2ad0002ad2ad00042d42d000000ad9bf51cc3f5a1e29eecb81d0c7b06eb","a":["192.168.178.200"],"tech":["Proxmox VE"],"words":345,"lines":55,"status_code":200,"content_length":2673,"failed":false,"knowledgebase":{"Forms":[{"type":"other"}],"PageType":"product","pHash":0},"cpe":[{"product":"proxmox_mail_gateway","vendor":"proxmox","cpe":"cpe:2.3:a:proxmox:proxmox_mail_gateway:*:*:*:*:*:*:*:*"},{"product":"proxmox","vendor":"proxmox","cpe":"cpe:2.3:a:proxmox:proxmox:*:*:*:*:*:*:*:*"}]}

```
**WAF / CDN:**
```
[-] No WAF detected by the generic detection
```

## Discovered API & Content

_no notable API or content discovered._

## API Schema & Endpoint Discovery

_no OpenAPI/Swagger specification exposed._
**Endpoints mined from JavaScript (122):**
```
/access
/access/acl
/access/domains
/access/groups
/access/openid
/access/openid/auth-url
/access/openid/login
/access/password
/access/permissions
/access/realm
/access/roles
/access/tfa
/access/ticket
/access/users
/cluster
/cluster/acme
/cluster/acme/account
/cluster/acme/challenge-schema
/cluster/acme/directories
/cluster/acme/meta
/cluster/acme/plugins
/cluster/acme/tos
/cluster/backup
/cluster/backup-info
/cluster/backup-info/not-backed-up
/cluster/ceph
/cluster/ceph/flags
/cluster/ceph/metadata
/cluster/ceph/status
/cluster/config
/cluster/config/apiversion
/cluster/config/join
/cluster/config/nodes
/cluster/config/qdevice
/cluster/config/totem
/cluster/firewall
/cluster/firewall/aliases
/cluster/firewall/groups
/cluster/firewall/ipset
/cluster/firewall/macros
/cluster/firewall/options
/cluster/firewall/refs
/cluster/firewall/rules
/cluster/ha
/cluster/ha/groups
/cluster/ha/resources
/cluster/ha/rules
/cluster/ha/status
/cluster/ha/status/current
/cluster/ha/status/manager_status
```

## Access Control & Misconfiguration

_no 401/403 access-control bypass found._
_no CORS reflection, host-header injection, or notable well-known files._

## Service CVEs & Host Vulns

_no host-level vulnerabilities detected._

## Web Vulnerabilities (nuclei)

_no web vulnerabilities detected by nuclei templates._

## Active Injection & Breaking

Findings from DAST fuzzing and attempts to provoke server errors (500s).
_no injection or breaking findings detected._

## Provoked Server Errors (5xx)

Deep fault injection: malformed bodies, type confusion, oversized input, verb tampering.
_no 5xx responses provoked (server handled all malformed input gracefully)._

## Cross-site scripting (dalfox)

_no verified XSS found._

## SQL injection (sqlmap)

_no injectable parameters confirmed._

## Credential Brute

_no weak credentials found._

## Denial-of-Service Exposure


## Reproduction (copy-paste PoCs)

Generated `pocs.sh` (review before running):
```bash

```

## Coverage Gaps — Missing Tools

The following tools were **not installed**, so their checks were skipped. Absence of a finding in those areas is not evidence of safety — install and re-run.
| Tool | Skipped check(s) |
|---|---|
| `waybackurls` | not exercised |

Install hints: pipx/go install for ProjectDiscovery tools (naabu, katana, nuclei, httpx, subfinder), `pacman`/AUR for nmap, sqlmap, hydra, nikto, wrk, slowhttptest, jq; `go install github.com/lc/gau` and `.../tomnomnom/waybackurls` for passive URL harvest.

## Industry Best Practices & Remediation

Use these industry-standard guides to remediate the findings above:

### 1. Web & API Security
- **[OWASP Top 10](https://owasp.org/www-project-top-ten/):** Remediation for XSS, SQLi, and Auth issues.
- **[OWASP API Security](https://owasp.org/www-project-api-security/):** Hardening for discovered API endpoints.
- **[OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/):** Specific technical fixes for all findings.

### 2. Infrastructure & Hardening
- **[NIST SP 800-123](https://csrc.nist.gov/publications/detail/sp/800-123/final):** General server security and OS hardening.
- **[NIST SP 800-53](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final):** Comprehensive security controls (IA/AC families).
- **[CIS Benchmarks](https://www.cisecurity.org/benchmark):** Step-by-step service-specific hardening guides.

### 3. Resilience & DoS
- **[OWASP DoS Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html):** Strategies for rate-limiting and WAF configuration.

---
_Blackbox assessment: absence of a finding is not proof of safety. Re-run after remediation._

Machine-readable summary: `findings.json`.
