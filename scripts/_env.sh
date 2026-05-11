# Sourced by other scripts. Loads .envrc if direnv is not active.
# Idempotent — safe to source many times.

if [ -f ".envrc" ]; then
  set -a
  # shellcheck disable=SC1091
  . .envrc
  set +a
fi
