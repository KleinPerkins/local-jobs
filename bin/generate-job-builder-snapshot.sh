#!/usr/bin/env bash
# Emit the job-builder canvas snapshot as one JSON object on stdout:
#   { schema, generated_at, types: [describe-types…], instances: [current…] }
#
# `types` is the machine-readable `describe-types` superset (schemas +
# update-field matrix); `instances` are the current managed instances so the
# canvas can pre-fill an update-job form. Pure read — idempotent apart from the
# generated_at timestamp — and honors the same LOCAL_JOBS_* env as every other
# bin script (via lib/common.sh). The job-builder canvas embeds this verbatim;
# regen manually after add-job-type / add-job / update-job.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

registry_py builder-snapshot
