# remove-nvidia-integration: parte do vega-cli

Proposta-mãe: [lyra-ecosystem/openspec/changes/remove-nvidia-integration](https://github.com/lyra-os-linux/lyra-ecosystem/tree/main/openspec/changes/remove-nvidia-integration), aprovada em 31/10/2026.

- Sai Hardware e Kernel → NVIDIA (`lib/nvidia.sh`) e o `source` em `bin/vega`. O menu não consulta capacidades: fica sem NVIDIA mesmo com um `vegad` antigo que ainda anuncia `nvidia-official-v1`.
- Sai o prazo especial de 2 horas do `InstallNvidia` em `lib/dbus.sh`; `lib/transaction.py` deixa de aceitar a assinatura `b` e recusa o método antes de conectar ao D-Bus.
- README: a seção NVIDIA vira uma frase apontando o procedimento do openSUSE em <https://lyraos.com.br/docs/>.
- 5.3.0, sem mudar o `Requires: vegad >= 5.6.2` (funciona com `vegad` antigo e novo).
