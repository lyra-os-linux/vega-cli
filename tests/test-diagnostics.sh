#!/usr/bin/env bash
# Textos do diagnóstico no vega-cli (add-cli-diagnostics): funções puras
# sobre JSON do vegad, com capturas reais da workstation (redigidas) e
# exemplos com achados.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$repo_root/tests/fixtures"
# shellcheck source=/dev/null
source "$repo_root/lib/diagnostics.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { [[ "$1" == *"$2"* ]] || fail "esperava \"$2\" em: $1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "não esperava \"$2\" em: $1"; }

# Resumo da verificação semanal: mostra uma vez por job.
periodic="$(cat "$fixtures/last-periodic.json")"
text="$(TZ=America/Sao_Paulo vega::diag::periodic_summary "$periodic" 0)"
has "$text" "1 novidade(s)"
has "$text" "• A sincronização de hora"
[ -z "$(vega::diag::periodic_summary "$periodic" 27)" ] || fail "resumo repetido para um job já visto"
[ -z "$(vega::diag::periodic_summary '[0,0,0,[],[]]' 0)" ] || fail "resumo sem verificação"
[ -z "$(vega::diag::periodic_summary '[30,1793364040,0,[],[]]' 0)" ] || fail "resumo sem novidades"

# Relatório: veredito por teste e só atenção e falha.
report="$(cat "$fixtures/report-findings.json")"
text="$(vega::diag::report_text "$report")"
has "$text" "Integridade de pacotes: 1 arquivo alterado"
has "$text" "[FALHA] Rede e internet: O DNS não traduz nomes"
has "$text" "porta 9000"
lacks "$text" "Secure Boot"
has "$(vega::diag::report_text "$(jq '.stages=[.stages[3]]' <<<"$report")")" "Nenhum problema encontrado."

# Corrigir: um item por achado com conserto, pelo índice dentro da etapa.
remedies='[[["packages",0,"reinstall-packages"],["security",1,"close-port"],["security",2,"close-port"]]]'
mapfile -t items < <(vega::diag::remedy_items "$remedies" "$report")
[ "${#items[@]}" -eq 3 ] || fail "esperava 3 itens: ${items[*]}"
[ "${items[1]%%$'\t'*}" = "security:1" ] || fail "referência errada: ${items[1]}"
has "${items[2]}" "porta 9000"

# Rede: os passos reais da workstation e um DNS quebrado.
text="$(vega::diag::network_text "$(cat "$fixtures/report-network.json")")"
has "$text" "Cabo ou Wi-Fi   funcionando"
has "$text" "A conexão está funcionando."
text="$(vega::diag::network_text "$report")"
has "$text" "DNS             AQUI ESTÁ O PROBLEMA"
has "$text" "Internet        não testado"
has "$text" "• O DNS não traduz nomes"

# Liberar espaço: só o que pode ser limpo; kernels e snapshots desmarcados.
[ -z "$(vega::cleanup::items "$(cat "$fixtures/cleanup-scan.json")")" ] || fail "nada para limpar na captura real"
mapfile -t items < <(vega::cleanup::items "$(cat "$fixtures/cleanup-scan-full.json")")
[ "${#items[@]}" -eq 4 ] || fail "esperava 4 categorias: ${items[*]}"
has "${items[0]}" $'coredumps\tRelatórios de falha (core dumps) — 256 MiB\ton'
has "${items[2]}" $'\toff'
has "${items[3]}" "pelo menos 4, tamanho desconhecido"
[ "$(vega::diag::bytes 268435456)" = "256 MiB" ] || fail "bytes"
[ "$(vega::diag::bytes 1610612736)" = "1.5 GiB" ] || fail "bytes GiB: $(vega::diag::bytes 1610612736)"

echo "diagnostics: ok"
