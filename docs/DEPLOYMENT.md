# Deploying the public reference & demo server

The OGC certification procedure needs a **publicly reachable** QGIS Server: OGC's own
TEAM Engine at `cite.opengeospatial.org` reaches across the internet to test it. The
[QGIS wiki](https://github.com/qgis/QGIS/wiki/OGC-compliance-for-QGIS) makes
*"confirm the reference QGIS server demo is operational"* step 2 of the process.

This deploys that server — certification endpoints for OGC, and a landing page for humans.

## Prerequisites

- A VPS with Docker Engine and the Compose plugin.
- A domain with `A`/`AAAA` records pointing at it. Caddy needs ports **80 and 443**
  reachable from the internet to complete the ACME challenge.
- Firewall open on 22, 80, 443 only.

## First deploy

```bash
sudo mkdir -p /opt/qgis-ogc-cert && sudo chown "$USER" /opt/qgis-ogc-cert
git clone <this-repo> /opt/qgis-ogc-cert && cd /opt/qgis-ogc-cert

cp deploy/.env.prod.example .env
$EDITOR .env          # SITE_ADDRESS, ACME_EMAIL, OGC_PUBLIC_HOST, QGIS_TAG, QGIS_VERSION_SLUG

./deploy/deploy.sh
```

`deploy.sh` stages the test data, pulls images, starts `qgis-server`, `nginx` and `caddy`,
then waits for `https://$SITE_ADDRESS/endpoints.json` to answer.

Set `OGC_PUBLIC_HOST` to the same value as `SITE_ADDRESS`. It is what QGIS Server
advertises in the URLs it publishes, and it is baked into the WMS `MetadataURL`s at
bootstrap — change it and re-run `./scripts/bootstrap.sh`.

### Start on boot

```bash
sudo cp deploy/qgis-ogc-cert.service /etc/systemd/system/
sudo $EDITOR /etc/systemd/system/qgis-ogc-cert.service   # User=, WorkingDirectory=
sudo systemctl daemon-reload
sudo systemctl enable --now qgis-ogc-cert
```

## Endpoints

With `QGIS_VERSION_SLUG=3_44`, mirroring the QGIS.org reference server:

| Path | Purpose |
|---|---|
| `/qgisserver_3_44_teamengine` | WMS 1.3.0 certification |
| `/certification_ogcapif_qgisserver_3_44/wfs3/` | OGC API Features certification |
| `/demo/wms`, `/demo/ogcapi` | demo (WMS, WFS, WMTS, OGC API) |
| `/` | landing page |
| `/endpoints.json` | machine-readable endpoint map |

## Upgrading the QGIS version

```bash
$EDITOR .env          # QGIS_TAG=3.44, QGIS_VERSION_SLUG=3_44
./deploy/deploy.sh
```

The endpoint paths change with the slug, which is intended — certification is per
version, and the old URLs should not silently start serving a new build.

**One QGIS version per deployment.** The naming supports running several side by side,
but that needs an additional `qgis-server` service and matching location block per
version. Not implemented.

## Security

**Never run the `tools` profile on a public host.** The `runner` service mounts the
Docker socket and uses host networking — root-equivalent control of the daemon. It is
profile-gated, the systemd unit names services explicitly, and `deploy.sh` refuses if
`--profile tools` is passed. Test suites are meant to be run from a workstation against
the public endpoints, not on the server.

In place by default:

| Control | Where |
|---|---|
| TLS + HSTS, `nosniff`, `Referrer-Policy`, no `Server` header | `deploy/Caddyfile` |
| Rate limit + connection cap per IP | `OGC_RATE_LIMIT`, `OGC_RATE_BURST`, `OGC_CONN_LIMIT` |
| Render size caps (upstream default is *unlimited*) | `QGIS_SERVER_WMS_MAX_WIDTH` / `_HEIGHT` |
| Feature page cap | `QGIS_SERVER_API_WFS3_MAX_LIMIT` |
| Body size cap, no directory listing, no `server_tokens` | `nginx/default.conf.template` |
| nginx bound to loopback; only Caddy is public | `HTTP_BIND=127.0.0.1` |
| `no-new-privileges`, log rotation, `restart: unless-stopped` | `deploy/docker-compose.prod.yml` |
| Data mounted read-only | `docker-compose.yml` |

Do not lower the rate limits without measuring a real conformance run against the new
value. At 10 r/s a TEAM Engine run drew 180 × HTTP 503 and WMS 1.3.0 fell from 185 passed
to 91 — throttling the suite is the one failure mode this server cannot have.

### Backups

No user data is stored; `data/` is fully reproducible via `./scripts/bootstrap.sh`. Worth
keeping: `.env`, and the `caddy_data` volume (ACME account key and certificates — losing
it forces re-issuance and can hit Let's Encrypt rate limits).

## Getting certified

Per the QGIS wiki, once the server is live:

1. Check the CI OGC workflow passes for the LTR branch
   ([`ogc.yml`](https://github.com/qgis/QGIS/actions/workflows/ogc.yml)). Locally,
   `make all` is the equivalent pre-flight.
2. Confirm the reference server answers — this deployment.
3. Log in at
   [opengeospatial.org/resource/products/registration](http://www.opengeospatial.org/resource/products/registration)
   with maintainer credentials and create an entry for the service/version.
4. Create a session at [cite.opengeospatial.org/teamengine](http://cite.opengeospatial.org/teamengine)
   pointing at your endpoint.
5. **Uncheck** raster elevation, vector elevation and time.
6. **Do not close the popup** — it holds the logs. Manually validate the three generated
   images when prompted.
7. Download the logs / HTML report and **keep the session ID**; the successful session ID
   and name go on the certification form.
8. Collect the certification logo and send it to the QGIS.org team.

> The reports this repository produces (`reports/<suite>/teamengine.xml`) come from *our*
> TEAM Engine and have **no standing with OGC**. They are regression signal: they tell you
> whether booking the session is worth it. Only a session on OGC's instance is certifiable.

Certification cannot be fully automated — step 6 requires a human to eyeball three images.

Contact for the QGIS certification process: `ogc at qgis dot org`.

## Troubleshooting

**Certificate won't issue.** Ports 80 and 443 must be reachable publicly and DNS must
resolve to this host. `docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml logs caddy`.

**Advertised URLs are wrong.** Check `GetCapabilities` `OnlineResource` and the OGC API
`links[].href`. They must be `https://$SITE_ADDRESS/...`. If they show `http://` or the
wrong host, `OGC_PUBLIC_HOST` is not set to the public domain. Note that QGIS Server's
OGC API Features implementation ignores `X-Forwarded-*`, `QGIS_SERVER_SERVICE_URL` and
`X-Qgis-Service-Url` alike — it builds links from `SERVER_NAME` plus the `HTTPS` and
`SERVER_PORT` CGI variables, which `nginx/qgis_fastcgi.inc.template` derives from the
proxied scheme. Getting this wrong truncates an OGC API conformance run to its
landing-page tests.

**Everything 503s.** The rate limiter. See above.
