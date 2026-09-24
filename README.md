# Zabbix MSP Monitoring via ImmyBot

Deploys and configures Zabbix Agent 2 on Windows endpoints across many client tenants using
[ImmyBot](https://www.immy.bot/), reporting to a central Zabbix server run with Docker Compose.

## Design

- **Active checks only.** Agents connect out to the server on `10051`; passive checks are disabled
  (`Server=` empty), so no inbound firewall rules are needed on client networks.
- **Autoregistration by HostMetadata.** Each client gets a unique secret token, e.g.
  `Client_ACME-<token>`. A Zabbix autoregistration action matching `Host metadata contains Client_ACME-<token>`
  places the host in that client's host group (e.g. `Clients/ACME`) and links templates.
  Treat these tokens as secrets: anyone holding one can register hosts into that client's group.
- **Hostnames** default to `<ClientCode>-<COMPUTERNAME>`, where `ClientCode` is parsed from the HostMetadata.
- **Optional PSK encryption** between agent and server.

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

| Name | Type | Required | Notes |
|---|---|---|---|
| `Server` | Uri/Text | yes | e.g. `zabbix.example.com` or `https://zabbix.example.com` |
| `HostMetadata` | Text | yes | `Client_<CODE>-<token>` |
| `Hostname` | Text | no | Defaults to `<CODE>-<COMPUTERNAME>` |
| `RefreshActiveChecks` | Number | no | 60–3600, default 60 |
| `EnablePSK` | Boolean | no | Default false |
| `TLSPSKIdentity` | Text | if PSK | |
| `PresharedKey` | Password | if PSK | 32–512 hex characters |

### What Set does

1. Backs up `zabbix_agent2.conf` (and the PSK file).
2. Removes every managed key and appends a single managed block.
3. Writes the PSK file with an ACL restricted to SYSTEM and Administrators.
4. Validates with `zabbix_agent2.exe -T`, then restarts the service. On failure, restores the backup and throws.

Test reports drift if any managed key is missing, duplicated, or wrong, if the PSK differs, or if the
service isn't running with automatic startup.

### Uninstall

Removes the MSI (by UpgradeCode), any leftover service and firewall rules, and the install folder,
including the config, PSK, and backups that contain the client token. Delete or disable the host in
Zabbix afterwards so its nodata triggers don't fire.
