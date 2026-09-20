#!/bin/bash
# Kept because the Makefile names it; xilinx.sh does the work.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/xilinx.sh" vivado "$@"
