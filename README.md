# Zabbix MSP Monitoring via ImmyBot

Deploys and configures Zabbix Agent 2 on Windows endpoints across many client tenants using
[ImmyBot](https://www.immy.bot/), reporting to a central Zabbix server run with Docker Compose.

## Design

- **Active checks only.** Agents connect out to the server on `10051`; passive checks are disabled
  (`Server=` empty), so no inbound firewall rules are needed on client networks.
- **HostMetadata is the client code** (e.g. `ACME`, `Contoso_Ltd`). It prefixes the hostname
  and, with PSK enabled, selects the Zabbix host group `Clients/<CODE>` (case-sensitive). The legacy
  `Client_<CODE>-<token>` / `Clients_<CODE>-<token>` format is still accepted and parsed to `<CODE>`.
  The client code is not a secret: if you use autoregistration actions keyed on it, anyone who knows
  a code can register hosts into that client's group.
- **Hostnames** default to `<CODE>-<COMPUTERNAME>`.
- **Per-host PSK (optional, per-tenant switch).** Each endpoint generates its own 256-bit key. The Set
  script pushes it to Zabbix through the API and creates the host if needed. The PSK identity is the
  Zabbix hostname.

## Server (`docker-compose.yaml`)

PostgreSQL, Zabbix server, and the Zabbix web frontend behind Traefik (HTTPS via Let's Encrypt).

```sh
cp .env.example .env    # then set a real password, hostname, and ACME email
docker compose up -d
```

| Variable | Purpose |
|---|---|
| `POSTGRES_PASSWORD` | Database password |
| `ZBX_WEB_HOST` | Public hostname for the web UI; must resolve to this host |
| `ACME_EMAIL` | Let's Encrypt registration email |

Ports: `80`/`443` (Traefik, web UI) and `10051` (agent/proxy connections). Port 80 must be reachable
from the internet for the Let's Encrypt HTTP challenge.

## ImmyBot scripts

| File | Role |
|---|---|
| `Custom_Zabbix_Agent_Deploy.ps1` | Configuration Task **Set** script |
| `custom_zabbix_test.ps1` | Configuration Task **Test** script |
| `Custom_Zabbix_Uninstall.ps1` | Software **Uninstall** script |

Install the agent itself with ImmyBot's global Zabbix MSI install and dynamic-version scripts; these
scripts manage configuration only.

The Test/Set scripts run in **separate-script mode** and deliberately have **no `param()` block**:
ImmyBot injects task parameters as variables, and a `param()` block would shadow them with `$null`.
The "resolve parameters" section must stay identical in both scripts.

### Task parameters

Names must match the ImmyBot task exactly. Both scripts log which parameters were received
(`Task params received: ...`), which is the quickest way to debug a missing value.

| Name | Type | Required | Hidden | Default | Notes |
|---|---|---|---|---|---|
| `Server` | Uri | yes | no | `https://zabbix.example.com` | Accepts a URL or a bare host (`host` or `host:port`). Only the host is used; the agent always gets `ServerActive=<host>:10051`. |
| `Hostname` | Text | no | no | `$env:COMPUTERNAME` | Leave at the default to get `<CODE>-<COMPUTERNAME>`: the scripts treat the literal `$env:COMPUTERNAME` (or blank) as "no override" and add the client-code prefix. Any other value is used verbatim as the Zabbix hostname. Allowed: letters, digits, space, `.` `-` `_` (max 128). |
| `HostMetadata` | Text | yes | no | — | Client code, e.g. `Contoso_Ltd`. Letters, digits, `_`, `-`; max 64. |
| `RefreshActiveChecks` | Number | no | no | `60` | Seconds, 60–3600. |
| `EnablePSK` | Boolean | no | yes | `true` | Per-host PSK plus API host registration. Set a tenant-level override to `false` to opt a tenant out. If the parameter is missing entirely, the scripts fall back to `false`. |
| `ZabbixApiToken` | Password | if PSK | yes | — | Zabbix API token. See [API token permissions](#api-token-permissions). |
| `ZabbixApiUrl` | Uri | no | no | `https://<Server host>/api_jsonrpc.php` | `/api_jsonrpc.php` is appended if missing. |
| `TemplateIds` | Text | if PSK and the host is new | no | — | Numeric template IDs, separated by commas, semicolons, or spaces. Set refuses to create a host with no templates. |
| `ProxyId` | Text | no | — | — | Proxy ID for tenants monitored through a Zabbix proxy (used only on host create). Read by the scripts but **not currently defined in the task**; add it to the task if needed. |

The "Required" column describes what the scripts enforce. Missing `Server` or `HostMetadata` makes
Test return non-compliant and Set exit without changes. The API parameters are read only when
`EnablePSK` is true.

### PSK prerequisites

- **Host group:** `Clients/<CODE>` must exist, and so must its parent `Clients`. Set checks for the
  group before it changes anything and fails if the group is missing.
- **API credentials:** an API token for a dedicated service user, set up as described in the next section.

### Zabbix API setup

Create a least-privilege service account for ImmyBot. Paths are for the Zabbix 7.0 frontend.

**1. User role:** *Users → User roles → Create user role*

| Setting | Value |
|---|---|
| Name | `ImmyBot API` |
| User type | **Admin** (`host.create` and `host.update` are not available to the User type) |
| Access to UI elements | Uncheck everything |
| Access to API | Enabled, **Allow list**: `host.create`, `host.get`, `host.update`, `hostgroup.get` |
| Access to actions | Uncheck everything, including *Default access to new actions* |

**2. User group:** *Users → User groups → Create user group*

| Tab | Setting |
|---|---|
| User group | Name `ImmyBot API`. *Frontend access*: Disabled. |
| Template permissions | **Read** on the template groups that contain the templates in `TemplateIds`, including the group of the wrapper template. |
| Host permissions | **Read-write** on `Clients` and all `Clients/*` subgroups. |

Check that newly created `Clients/<CODE>` groups inherit this permission. If they don't, add each
new group here when you onboard a client. Set fails with "Host group ... not found or not visible"
if the API user can't see the group.

**3. User:** *Users → Users → Create user*

- Username: e.g. `svc-immybot-api`. Groups: `ImmyBot API`.
- Password: a long random value that is never used, since the account authenticates only by token.
- *Permissions* tab: role `ImmyBot API`.

**4. API token:** *Users → API tokens → Create API token*

- User: `svc-immybot-api`. Set an expiry date that matches your rotation policy.
- Copy the token when it's shown; it can't be retrieved later. Store it in the ImmyBot
  `ZabbixApiToken` parameter as a global or tenant-level value.

**5. Verify** that the token works and can see the client host groups:

```sh
curl -s https://zabbix.example.com/api_jsonrpc.php \
  -H 'Content-Type: application/json-rpc' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","method":"hostgroup.get","params":{"output":["name"],"search":{"name":"Clients/"}},"id":1}'
```

The response should list every `Clients/*` group. If it returns an error, check that the role's
API access is enabled and the token is active. If the list is empty, fix the host permissions on
the user group.

**Finding IDs:** the role can't call `template.get` or `proxy.get`, so look IDs up in the frontend.

- **Template IDs:** *Data collection → Templates*. Open the template; the ID is the `templateid=`
  value in the URL.
- **Proxy ID:** *Administration → Proxies*. Open the proxy; the ID is the `proxyid=` value in the URL.

If a host with the target name already exists in a group the API user can't see, `host.create` fails
with "already exists". Set reports this as a visibility problem: move the host into `Clients/<CODE>`,
or grant the user group access to the host's current group.

### What Set does

Without PSK:

1. Backs up `zabbix_agent2.conf` to `zabbix_agent2.conf.immybak`.
2. Removes every managed key and appends a single managed block.
3. Validates with `zabbix_agent2.exe -T`, sets the service to Automatic, and restarts it. On failure,
   restores the backup and throws.

With PSK:

0. **API:** resolves host group `Clients/<CODE>`. Fails before anything is touched.
1. **Endpoint:** resolves the hostname. Reuses `zabbix_agent2.host.psk` if it holds a valid 64-hex key;
   otherwise generates a new 256-bit key. Restricts the file's ACL to SYSTEM and Administrators.
2. **API:** updates the existing host, or creates it in `Clients/<CODE>` with `TemplateIds` (and
   `ProxyId`), setting `tls_connect=PSK` and `tls_accept=unencrypted+PSK` so there is no gap during
   cutover.
3. **Endpoint:** writes the config as above with `TLSConnect`/`TLSAccept=psk`,
   `TLSPSKIdentity=<hostname>`, and `TLSPSKFile`. Deletes the legacy shared `zabbix_agent2.psk` and its
   backup. On failure, reverts the host's `tls_accept` to its previous value.
4. **API:** tightens the host to `tls_accept=PSK` only.

Managed config keys: `Server`, `ServerActive`, `Hostname`, `HostMetadata`, `RefreshActiveChecks`,
`StartAgents`, `TLSConnect`, `TLSAccept`, `TLSPSKIdentity`, `TLSPSKFile`. `StartAgents` and the
PSK keys (when PSK is off) are removed, not set.

### What Test checks

- Each desired key appears exactly once with the expected value; managed keys that should not be set
  (`StartAgents`, and the PSK keys when PSK is off) are absent.
- The service `Zabbix Agent 2` exists, is running, and starts automatically.
- With PSK:
  - The per-host PSK file is valid.
  - The legacy shared PSK file is gone.
  - The Zabbix host exists and is visible to the API user, with `tls_connect` and `tls_accept` both
    set to PSK.
  - Membership in `Clients/<CODE>` is reported but not enforced.

### Uninstall

Removes the MSI (by UpgradeCode), any leftover service and firewall rules, and the install folder,
including the config, PSK files, and backups that contain the client code and PSK. Delete or disable
the host in Zabbix afterwards so its nodata triggers don't fire.
