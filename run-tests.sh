#!/bin/bash
# Runs the extractor corpus test.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E "error|warning:" || true
./.build/release/OTPeek --self-test
