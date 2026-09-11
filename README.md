# QGIS-OGC-Cert

A Docker Compose harness that runs the OGC **Executable Test Suites** (ETS) against any
published QGIS Server image, using [pyogctest](https://github.com/rouault/pyogctest) and
the official OGC [TEAM Engine](https://github.com/opengeospatial/teamengine) harness —
the same tooling as upstream QGIS CI.

Upstream QGIS verifies compliance in
[`.github/workflows/ogc.yml`](https://github.com/qgis/QGIS/blob/master/.github/workflows/ogc.yml),
which builds QGIS from source — around an hour before the first test runs. This project
does the same testing against the **published `qgis/qgis-server` images**, so you can
answer *"is QGIS Server 3.44 still WMS 1.3.0 compliant?"* in minutes, and diff results
across releases.

Docker is the only prerequisite — no host Python, no virtualenv.

## Quickstart

```bash
cp .env.example .env      # optional — every value has a default
make bootstrap            # fetch test data (~17 MB)
make all                  # run both suites
make reports              # list the generated reports
```

Single suite: `make wms130` or `make ogcapif`. Another release: `QGIS_TAG=stable make all`.

To deploy this publicly — as an OGC certification reference server and live demo — see
**[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**.

## Scope

pyogctest implements exactly two suites, and this harness covers both:

| Suite | ETS image (pinned by pyogctest) |
|---|---|
| WMS 1.3.0 | `ogccite/ets-wms13` |
| OGC API Features 1.0 | `ogccite/ets-ogcapi-features10:1.0-teamengine-5.4` |

**The ETS versions are deliberately not configurable.** pyogctest hardcodes them so that
results line up with the suites QGIS is formally certified against. Newer ETS builds test
more and will report failures the certification-era suites never checked — useful for
QGIS development, misleading as a compliance statement. See *Known gaps* below.

**WFS is out of scope.** WFS 1.1.0 is only partially compliant in QGIS Server and
pyogctest has no WFS driver; WFS 2.0 is *not implemented at all* — QGIS Server advertises
only WFS 1.0.0/1.1.0, and its 2.0-era functionality is exposed through OGC API Features
instead. An earlier iteration of this harness ran both via a bespoke REST client; that
was removed in favour of a single upstream-aligned driver.

## Results

Against `qgis/qgis-server:ltr`, from a clean `make bootstrap && make all` on 2026-09-11:

| Suite | Result | Time |
|---|---:|---:|
| WMS 1.3.0 | **185 passed, 0 failed** | 22 s |
| OGC API Features 1.0 | **56 passed, 0 failed** | 15 s |

Both suites are fully green. WMS 1.3.0 covers the `basic`, `queryable` and
`recommended` conformance classes — `basic` being the one required for certification.
The 56 OGC API Features tests match the count the
[QGIS developer docs](https://docs.qgis.org/testing/en/docs/developers_guide/ogcconformancetesting.html)
quote for a passing run.

### Known gaps

Run with the *current* ETS (`ogccite/ets-ogcapi-features10:1.9-teamengine-6.0.0-RC2`)
rather than the 2020-era build pyogctest pins, OGC API Features reports **3 failures**
against QGIS 3.x's `/wfs3` draft endpoint — conformance-class discovery at
`/conformance`, and feature-id checks on `/items`. Those are real findings about the
draft endpoint, not harness bugs. They are out of scope here by design (this harness
reports compliance against the certified baseline), but worth knowing before quoting
the green table above.

## How it works

```
                    ogc-cert network
  ┌────────────┐   ┌───────┐      ┌──────────────┐
  │ TEAM       │──▶│ nginx │─────▶│ qgis-server  │
  │ Engine     │   │ :80   │ 9993 │ (official    │
  │ (pyogctest │   └───────┘      │  image)      │
  │  spawns)   │       │          └──────────────┘
  └────────────┘       └── /wms13/metadata (static)
        ▲
        │ REST on localhost:8081
  ┌──────────┐
  │ runner   │  pyogctest — mounts the Docker socket, host networking
  └──────────┘
```

**One QGIS Server, two endpoints.** A single `qgis/qgis-server` container is fronted by
our own nginx, which selects the project per location with the `QGIS_PROJECT_FILE`
fastcgi_param — the trick upstream's `.ci/ogc/nginx.conf` uses. We talk to the image's
documented FastCGI port **9993**, so its own entrypoint (nginx + Xvfb) is left untouched
and nothing is rebuilt.

Endpoints follow the QGIS.org reference-server convention, named from
`QGIS_VERSION_SLUG` (default `ltr`):

| Endpoint | Project |
|---|---|
| `/qgisserver_<slug>_teamengine` | `teamengine_wms_130.qgs` (CITE dataset) |
| `/certification_ogcapif_qgisserver_<slug>` | `world.qgs` |
| `/demo/wms`, `/demo/ogcapi` | `world.qgs` — human-facing |
| `/wms13/metadata/` | static MetadataURL documents |
| `/`, `/endpoints.json` | landing page and its endpoint map |

**pyogctest owns TEAM Engine.** It pulls, starts and removes the ETS container itself
(fixed name `pyogctest`, published on `TE_PORT`, attached to the `ogc-cert` network so it
can resolve `nginx`). There are therefore no `teamengine` services in
`docker-compose.yml`. While a suite runs you can browse the TEAM Engine UI at
`http://localhost:8081` (login `ogctest` / `ogctest`) — that UI is what a real OGC
certification submission is driven through.

### Gotchas worth knowing

- **The runner mounts the Docker socket**, which grants it root-equivalent control of the
  host Docker daemon. That is what pyogctest's design requires; it only ever runs the
  pinned OGC images. The socket path is auto-detected from your docker context, so
  rootless (`/run/user/<uid>/docker.sock`) and rootful both work.
- **`SERVER_NAME` must be the host the suite uses.** QGIS builds the absolute URLs it
  advertises from it; left as `$server_addr` the OGC API Features links come back as a
  bare container IP and the run stops after the landing-page tests. Set via
  `OGC_PUBLIC_HOST` and rendered into the nginx config with `envsubst`.
- **QGIS Server returns HTTP 200 for OGC `ServiceException`s.** Health checks must match
  on response *content*, never the status code. `scripts/run-suite.sh` does.
- **Interrupted runs leave a container named `pyogctest`**, which blocks the next run.
  `scripts/lib.sh` clears it automatically.
- **`pyogctest -x` writes `teamengine.xml` into the working directory** and ignores
  `-o`; `-o` only applies to `-f html`, which would replace the readable console output.
  `scripts/run-suite.sh` keeps the prompt format and files the XML into
  `reports/<suite>/` itself.
- **Don't use `pyogctest -s wms130 -e` to stage the CITE data.** It copies
  `teamengine_wms_130.qgs` into `data/` without unpacking the shapefiles beside it; the
  project then loads with no layers and QGIS Server stops answering the WMS endpoint
  altogether. `scripts/fetch_data.py` fetches and verifies the dataset instead.

## Test data

`make bootstrap` assembles `data/` via `scripts/fetch_data.py`, all SHA-256 verified:

- the WMS 1.3.0 CITE dataset (`shapefile/`, `raster/`, `gml/`, `mapinfo/`, `metadata/`)
  and `teamengine_wms_130.qgs`, from a pinned pyogctest commit;
- `MetadataURL`s rewritten to point at `OGC_PUBLIC_HOST`;
- the five files of `qgis-server-tutorial-data` needed from
  [QGIS-Training-Data](https://github.com/qgis/QGIS-Training-Data), fetched individually
  and SHA-256 verified by `scripts/fetch_data.py` — cloning that repository would cost
  467 MB for 4.8 MB of data.

Bumping a pinned ref means updating the checksums in `scripts/fetch_data.py`; it refuses
to proceed otherwise.

## Layout

```
docker-compose.yml              qgis-server, nginx, runner
runner/Dockerfile               pyogctest, pinned to a commit
nginx/default.conf.template     endpoint routing, rate limits, proxy maps
nginx/qgis_fastcgi.inc.template shared FastCGI wiring
www/index.html                  landing page
scripts/bootstrap.sh            test-data assembly
scripts/fetch_data.py           checksum-verified data download
scripts/run-suite.sh            orchestration + readiness checks
scripts/lib.sh                  shared helpers, socket + rootless detection
deploy/                         production overlay, Caddy, systemd, deploy.sh
docs/DEPLOYMENT.md              VPS deployment + OGC certification walkthrough
data/, reports/                 generated, gitignored
```

## References

- [OGC compliance for QGIS](https://github.com/qgis/QGIS/wiki/OGC-compliance-for-QGIS) (wiki)
- [QGIS OGC Conformance Testing](https://docs.qgis.org/testing/en/docs/developers_guide/ogcconformancetesting.html)
- [pyogctest](https://github.com/rouault/pyogctest) ·
  [ets-wms13](https://github.com/opengeospatial/ets-wms13) ·
  [ets-ogcapi-features10](https://github.com/opengeospatial/ets-ogcapi-features10)

---

Made with 💗 by [Kartoza](https://kartoza.com) | Donate! | GitHub
