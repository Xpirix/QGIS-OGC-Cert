#!/usr/bin/env python3
"""Fetch the test data the OGC suites need, into ./data.

Two datasets, both pinned by commit and verified by SHA-256 so tampering is
detectable:

* the WMS 1.3.0 CITE dataset and its QGIS project, from the pyogctest repo;
* world.qgs and friends from QGIS-Training-Data, for OGC API Features.

We deliberately do *not* use `pyogctest -s wms130 -e` for the WMS data. That
copies teamengine_wms_130.qgs into ./data but does not unpack the CITE
shapefiles alongside it, leaving a project whose layers all fail to load — at
which point QGIS Server stops answering the WMS endpoint entirely. pyogctest is
used only to run the suites.

Standard library only.
"""

from __future__ import annotations

import hashlib
import io
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

# Pinned commit of rouault/pyogctest (branch ogcapi_root). Bump deliberately,
# and update the checksums when you do.
PYOGCTEST_REF = "8f64a29496a3e84602c31a5a2525184b37fddcbd"
PYOGCTEST_RAW = (
    f"https://raw.githubusercontent.com/rouault/pyogctest/{PYOGCTEST_REF}/pyogctest/data"
)
WMS_FILES = {
    "data-wms-1.3.0.zip": "306d7fd3967bc3a30d96b3b4e56c3ecf0f86e82343317dde71f49da1174b101f",
    "teamengine_wms_130.qgs": "03d635b320674ecb9b772b630dd374d6901bd8233cdf32e3cc631cdecc01f239",
}

# Pinned commit of qgis/QGIS-Training-Data. That repository is ~467 MB and we
# need 4.8 MB of it, so fetch the individual files rather than cloning.
TRAINING_REF = "fd26dd88e39b9aec550eea450cec18d02b1de3b5"
TRAINING_RAW = (
    f"https://raw.githubusercontent.com/qgis/QGIS-Training-Data/{TRAINING_REF}"
    "/exercise_data/qgis-server-tutorial-data"
)
TRAINING_FILES = {
    "Icons/compass_white.svg": "541b9c275dc7f6f8e7f4fbf26faaff744c8ed94c6844c62d509ab01a25584ca9",
    "Icons/menu_white.svg": "431aa634616eaa7b4284067207f4b183bde91e5fbb80d138b5dc946425cf5fe9",
    "Template/Material_design.qpt": "012adaa34e508a495ea8c249f84effc34de7f53971a410de73da7461131efcea",
    "naturalearth.sqlite": "f0a4b7e9a212682f7b09bab29c616db1f950bd1a13446ebe3c8e953558451651",
    "world.qgs": "908e92daf868b44f2774d371b0767dcd3dc5facf1b6cf116b45ad63d5d18b8a3",
}

DATA = Path("data")
TUTORIAL = DATA / "qgis-server-tutorial-data"


def log(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def download(name: str, expected_sha256: str, base: str) -> bytes:
    log(f"downloading {name}")
    with urllib.request.urlopen(f"{base}/{name}", timeout=300) as resp:
        blob = resp.read()
    actual = hashlib.sha256(blob).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"Checksum mismatch for {name}\n  expected {expected_sha256}\n"
            f"  got      {actual}\n"
            "Refusing to use it. If you bumped a pinned ref, update the checksums."
        )
    return blob


def set_metadata_host(project: Path, host: str, scheme: str = "http") -> None:
    """Point the project's MetadataURLs at the origin TEAM Engine will use.

    The WMS 1.3.0 suite dereferences every MetadataURL, so they must resolve
    from wherever the suite runs.

    The scheme matters: on an HTTPS deployment these must be https too, or
    GetCapabilities advertises a mix of schemes and the documents only resolve
    via an http->https redirect — which breaks outright if port 80 is closed.
    """
    text = project.read_text(encoding="utf-8")
    patched = re.sub(
        r"https?://[^/\"'<> ]+/wms13/metadata",
        f"{scheme}://{host}/wms13/metadata",
        text,
    )
    if patched != text:
        project.write_text(patched, encoding="utf-8")
    log(f"MetadataURLs -> {scheme}://{host}/wms13/metadata")


def fetch_wms(host: str, scheme: str = "http") -> None:
    project = DATA / "teamengine_wms_130.qgs"
    # data/metadata is bind-mounted by compose, which creates it empty if it is
    # missing — so its mere existence proves nothing. Check for real content.
    have_dataset = (DATA / "shapefile").is_dir() and any((DATA / "metadata").glob("*.xml"))
    if project.exists() and have_dataset:
        log("WMS 1.3.0 test data already present")
    else:
        blob = download("data-wms-1.3.0.zip", WMS_FILES["data-wms-1.3.0.zip"], PYOGCTEST_RAW)
        log("extracting CITE dataset into data/")
        with zipfile.ZipFile(io.BytesIO(blob)) as zf:
            zf.extractall(DATA)
        project.write_bytes(
            download(
                "teamengine_wms_130.qgs",
                WMS_FILES["teamengine_wms_130.qgs"],
                PYOGCTEST_RAW,
            )
        )
    set_metadata_host(project, host, scheme)


def fetch_training() -> None:
    if (TUTORIAL / "world.qgs").exists():
        log("OGC API Features test data already present")
        return
    for name, digest in TRAINING_FILES.items():
        target = TUTORIAL / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(download(name, digest, TRAINING_RAW))


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "nginx"
    scheme = sys.argv[2] if len(sys.argv) > 2 else "http"
    DATA.mkdir(parents=True, exist_ok=True)
    fetch_wms(host, scheme)
    fetch_training()
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
