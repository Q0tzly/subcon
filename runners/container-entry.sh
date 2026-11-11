#!/bin/bash
set -euo pipefail

job_dir="${SUBCON_JOB_DIR:?SUBCON_JOB_DIR required}"

driver_bin="${SUBCON_DRIVER_BIN:-subcon-driver-agy}"
rc=0
"$driver_bin" "$job_dir" || rc=$?
exit "$rc"
