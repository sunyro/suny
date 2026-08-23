suny

Cloudflare IP Rotate Manager for tunnel backends, with distributed health checks.

What it does

Stores multiple backend IPs for each Cloudflare A record.

Rotates the DNS record manually or by cron.

Optionally checks the next backend from distributed Check-Host nodes before switching DNS.

Tests the actual tunnel TCP port rather than relying only on ICMP ping.

Checks Iran plus multiple external regions.

Reports HEALTHY, DEGRADED, LIKELY FILTERED, OFFLINE, or UNKNOWN.

Skips a failed candidate during automatic rotation when health checking is enabled.

Keeps the rotation index unchanged unless the Cloudflare update succeeds.

Prevents overlapping automatic rotations with a lock.

Includes a menu option to uninstall suny completely.

Install

curl -fsSL https://raw.githubusercontent.com/sunyro/suny/main/install.sh | sudo bash
sudo suny

The installer installs curl, jq, and util-linux on apt-based systems.

Cloudflare API Token

Do not use a Global API Key or an unrestricted account token.

Create a scoped API Token with:

Zone -> DNS -> Edit

Zone -> Zone -> Read

Limit the token to only the zone(s) managed by suny.

Health checking

Health checks use Check-Host distributed nodes. The tunnel's real TCP port is tested (for example 443, 8443, or another port).

The classification is a heuristic:

HEALTHY: external reachability meets the configured threshold.

DEGRADED: Iran is reachable but external reachability is below the threshold.

LIKELY FILTERED: Iran is reachable while all selected external probes fail.

OFFLINE / UNREACHABLE: the Iran probe also fails.

UNKNOWN: the Check-Host service did not provide a usable result.

LIKELY FILTERED is not proof of censorship; firewalls, routing, provider outages, or a closed tunnel port can produce the same result.

A Check-Host API key is optional. Anonymous checks have conservative rate limits; a key can raise limits.

Menu

Set Cloudflare API Token

Add Domain

List Domains

Delete Domain

Rotate All Now

Rotate One Domain

Install Hourly Cron

Remove Cron

Health Check Domain

Set Check-Host API Key (optional)

Help: Cloudflare / Health Check

Uninstall suny

Exit

Domain format

The current format is:

name|zone_id|record_id|ip1,ip2,ip3|ttl|proxied|health_port|health_enabled|min_success

Example:

cdn.example.com|ZONE_ID|RECORD_ID|1.2.3.4,5.6.7.8,9.10.11.12|120|false|443|true|60

Old six-field entries remain readable; health checking defaults to disabled for them.

Security

The Cloudflare token is stored in /etc/suny/config.env with mode 600. The Check-Host API key, if configured, is stored there as well.

The uninstall option removes suny files, state, logs, cron, and the /usr/local/bin/suny symlink. It does not delete Cloudflare DNS records or remote servers.
