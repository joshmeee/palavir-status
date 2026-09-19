# palavir-status — the outside view

Every Uptime Kuma check in the Palavir homelab (~95 of them) runs on `docker01`, inside
the house. That makes two very different failures look identical:

* the site is down
* **our** internet is down

This repo is the second vantage point. A GitHub Action probes the public product URLs
from a runner outside the house every ~15 minutes and publishes the verdict to the
[`status`](../../tree/status) branch as `status.json`.

## Why it is public

Actions minutes are free and unmetered for public repositories. A `*/15` schedule in a
private repo costs roughly 2,900 minutes a month against a 2,000-minute allowance that
other scheduled jobs already share. Nothing here is sensitive: the URLs are published
product sites and the results are their up/down state.

## Files

| Path | What it is |
|---|---|
| `urls.json` | The probe targets. Edit this to add or drop a site. |
| `probe.sh` | The prober. Runs anywhere with `bash`, `curl` and `jq`. |
| `.github/workflows/external-probe.yml` | The schedule and the publish step. |

## How the verdict is read

`status.json` carries `verdict` = `ok` | `down` | `prober`.

`prober` means **every** target was unreachable, which is a statement about the runner's
own network, not about nine simultaneous outages. A degraded collector must never
publish a confident verdict about the world, so that case is deliberately not an alarm.
A site answering a real HTTP error (a 5xx) still counts as `down`.

## Two alarms, on purpose

1. **The wall.** `external-vantage.sh` on `docker01` reads `status.json` every 5 minutes
   and pushes to the Uptime Kuma monitor *external: public sites (GitHub)*, which also
   goes red if the file is stale — a schedule that quietly stopped is itself a failure.
2. **Josh's phone.** The workflow run goes red when a site is genuinely down, and GitHub
   emails the repo owner. That path does not touch the house internet, which matters:
   ntfy, Kuma and the wall all live on `docker01`.
