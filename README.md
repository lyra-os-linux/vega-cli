# Vega CLI

Interface de terminal do [Vega](https://github.com/lyra-os-linux/vega) —
`vega`, pensada para administrar máquinas/servidores acessados via SSH, sem
depender de ambiente gráfico. Reaproveita o
[`vegad`](https://github.com/lyra-os-linux/vegad) e o contrato
`org.lyraos.Vega1.*` ([`lyra-vega-dbus`](https://github.com/lyra-os-linux/lyra-vega-dbus))
já usados pelo `vega-gtk`; aqui muda só o frontend, que é shell script
(`bash`) + `dialog`.

## Dependências de runtime

- `dialog` — toda a interface
- `busctl` (do `systemd`, já dependência do resto do projeto) + `jq` —
  acesso a D-Bus (issue [#103](https://github.com/lyra-os-linux/vega/issues/103))
- `polkit` (com `pkttyagent`) — autorização de ações privilegiadas numa
  sessão sem agente gráfico

Só roda pelo terminal — não tem lançador de desktop (`.desktop`).

O frontend roda como o usuário da sessão. Consultas abrem sem autenticação;
o polkit solicita autorização apenas ao executar uma ação que altera o sistema.

## Estrutura

```
bin/vega        # entrypoint — resolve o próprio diretório (segue
                 # symlinks) e faz source dos módulos em lib/
lib/term.sh      # checagens de ambiente (dialog/busctl/jq instalados,
                 # TTY), registro do pkttyagent e limpeza do terminal
                 # ao sair
lib/ui.sh        # wrappers finos sobre `dialog` (menu, msgbox) com
                 # --backtitle/--stdout consistentes
lib/dbus.sh      # acesso ao vegad via `busctl --json=short` + `jq`
                 # (org.lyraos.Vega1.*), com tratamento de erro
                 # consistente
lib/menu.sh      # menu principal e navegação entre módulos
```

Cada módulo real (Painel, Software, Backup, ...) troca sua entrada em
`vega::main_menu` (`lib/menu.sh`) por uma função própria — sem precisar
alterar a estrutura do menu.

## Rodando localmente

```bash
./bin/vega
```

Precisa de um terminal interativo real (TTY) — não roda com stdin/stdout
redirecionado para um pipe ou arquivo.

## Resultados e erros de D-Bus

Os módulos recebem resultados por variável de saída para manter status e
mensagem de erro no mesmo processo Bash:

```bash
local data
if vega::dbus::call_data_into data System Ping; then
  printf '%s\n' "$data"
else
  vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" "Vega"
fi
```

`call_into` recebe o JSON completo; `call_data_into`, o array `data`;
`run_transaction_into`, a mensagem final da transação. O primeiro argumento
é o nome de uma variável escalar gravável do chamador. Os prefixos
`__vega_capture_` e `VEGA_DBUS_` são reservados. A captura usa um arquivo
temporário privado e remove as quebras de linha finais como `$(...)`.
Na falha, a saída fica vazia e `VEGA_DBUS_LAST_ERROR` contém o motivo atual;
uma chamada bem-sucedida limpa o erro anterior. Lotes devem salvar a última
falha antes de iniciar a chamada seguinte.

As variantes sem `_into` continuam disponíveis em stdout, mas capturá-las
com `$(...)`, pipes ou process substitution isola suas variáveis no subshell.
Não use esse padrão quando precisar consultar `VEGA_DBUS_LAST_ERROR` depois.
Os helpers do painel formatam a mensagem de erro antes de retornar seu texto.

Os testes usam `busctl` e diálogos simulados, sem acessar o barramento do
sistema ou executar operações administrativas:

```bash
./tests/test-dbus.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
python3 scripts/check-dbus-contract.py ../lyra-vega-dbus/dbus
```

A cobertura inclui erros Polkit/daemon/backend, status de saída, limpeza de
erro antigo, JSON inválido, transações, telas consumidoras e falha seguida de
sucesso em lote. Ela verifica transporte e apresentação das respostas, não
a autorização Polkit real. A correlação e a sincronização da espera dos sinais
de transação continuam sendo tratadas separadamente na
[issue #20](https://github.com/lyra-os-linux/vega-cli/issues/20).
