# add-cli-diagnostics: parte do vega-cli

Proposta-mãe: [lyra-ecosystem/openspec/changes/add-cli-diagnostics](https://github.com/lyra-os-linux/lyra-ecosystem/tree/main/openspec/changes/add-cli-diagnostics), aprovada em 30/10/2026.

- `lib/diagnostics.sh`: resumo da verificação semanal ao abrir (estado por usuário em `~/.local/state/vega-cli/periodic-seen`), Diagnóstico de saúde em Hardware e Kernel (rápido sem os testes de carga, um teste avulso, relatório, Corrigir por checklist com `RepairFindings`, Já vi, verificação periódica), Minha internet não funciona em Rede e Liberar espaço em Armazenamento.
- O progresso consulta `Current` a cada segundo: um job rápido termina antes da resposta do `Start`.
- `lib/transaction.py` aceita `Cleanup.Clean` só com uma lista tipada de ids e espera o `Finished(ust)` do próprio job.
- 5.2.0, `Requires: vegad >= 5.6.2` (as leituras sem senha pelo SSH).
