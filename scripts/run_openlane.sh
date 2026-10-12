#!/usr/bin/env bash
# Run the RTL-to-GDSII flow (OpenLane 2, sky130A).
#   bash scripts/run_openlane.sh [run-tag]
set -euo pipefail
cd "$(dirname "$0")/.."

# OpenLane's container can only read files inside the config folder,
# so copy the RTL next to config.json first.
rm -rf openlane/src
mkdir -p openlane/src
cp rtl/*.v openlane/src/

cd openlane
if [ "${1:-}" != "" ]; then
    openlane --dockerized --run-tag "$1" config.json
else
    openlane --dockerized config.json
fi

echo
echo "Done. Results: openlane/runs/<tag>/final/  (gds/, metrics.json, ...)"
