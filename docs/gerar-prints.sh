#!/bin/bash
# Regenera os prints do README a partir de uma execução REAL do script.
#
#   ./docs/gerar-prints.sh
#
# Monta duas instalações de Eclipse sintéticas num diretório temporário
# (as mesmas fixtures da suíte de testes), roda o script de verdade contra
# elas dentro de um pty, e converte a saída ANSI em SVG.
#
# Nenhuma instalação real é tocada e nada é baixado da rede.

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/lib/fixtures.sh
. "$ROOT/tests/lib/fixtures.sh"

DEMO=$(mktemp -d "${TMPDIR:-/tmp}/fluig-prints.XXXXXX")
trap 'rm -rf "$DEMO"' EXIT

CACHE="$DEMO/cache"
fixture_cache "$CACHE" > /dev/null

for nome in "Eclipse IDE 2026-03" "Eclipse IDE 2026-09"; do
    app=$(fixture_eclipse "$DEMO" "$nome" completo)
    fixture_model_plugin   "$app" 2.0.0.9 2.3.1
    fixture_eclipse_plugin "$app" 2.0.0.9 rhino
done

CAPTURA="$DEMO/captura.raw"

# O script lê de /dev/tty, então precisa de um pty: daí o `script`.
# As pausas dão tempo de ele chegar no prompt antes da resposta chegar.
( sleep 2; printf 'Eclipse IDE 2026-03\n'; sleep 4; printf '\n' ) | \
    script -q "$CAPTURA" env TERM=xterm-256color \
    "$ROOT/fluig-eclipse-fix.command" \
        --search-dirs "$DEMO" --cache-dir "$CACHE" > /dev/null 2>&1 || true

if ! grep -q "Correções concluídas" "$CAPTURA"; then
    echo "ERRO: a execução não chegou ao resumo final. Captura em $CAPTURA" >&2
    trap - EXIT
    exit 1
fi

# Faixas de linha sobre o texto limpo (ver ansi2svg.py --help)
python3 docs/ansi2svg.py "$CAPTURA" docs/print-selecao.svg \
    "fluig-eclipse-fix.command" 2 12
python3 docs/ansi2svg.py "$CAPTURA" docs/print-sucesso.svg \
    "fluig-eclipse-fix.command — resumo final" 58 78

echo "Prints regenerados. Confira as faixas de linha se a saída do script mudou."
