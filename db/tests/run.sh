#!/usr/bin/env bash
# run.sh - Delegado: las pruebas las ejecuta "ctl.sh test" (equivalente opcional de ctl.ps1 test).
# Uso: db/tests/run.sh [NN] [--evidence nombre]
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ctl.sh" test "$@"
