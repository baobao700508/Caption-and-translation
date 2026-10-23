#!/bin/bash
set -euo pipefail
exec /bin/bash "$(dirname "$0")/install-sat.sh" "${1:-sat-3l}"
