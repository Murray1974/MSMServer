set -euo pipefail
OUT=${1:-server_audit.txt}
rg -n -S \
  'app\.webSocket|webSocket\(|test-broadcast|instructorHub|availabilityHub|msmInstructorHub|broadcastJSON|broadcast\(|/ws/' \
  Sources > "$OUT"
echo "Wrote $OUT"
