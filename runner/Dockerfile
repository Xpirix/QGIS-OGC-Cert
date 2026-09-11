# Test driver: pyogctest, the same tool upstream QGIS CI uses.
#
# Kept in a container so the harness has no host-side Python or virtualenv
# requirement — Docker is the only prerequisite.
#
# pyogctest spawns its own TEAM Engine container through the Docker *Python
# SDK*, not the CLI, so this image needs the socket mounted at runtime but no
# docker binary installed.
FROM python:3.12-slim

# Pinned to a commit rather than the ogcapi_root branch head: an unpinned VCS
# install is a moving target and a supply-chain risk. Bump deliberately.
ARG PYOGCTEST_REF=8f64a29496a3e84602c31a5a2525184b37fddcbd

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    "git+https://github.com/rouault/pyogctest.git@${PYOGCTEST_REF}"

WORKDIR /work
ENTRYPOINT []
CMD ["bash"]
