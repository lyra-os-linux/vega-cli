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
- Python 3 e PyGObject/Gio (`python3-gobject` no openSUSE) — assinatura e
  correlação das transações, sem dependência de GTK ou sessão gráfica
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
a autorização Polkit real. As transações são verificadas também com conexões Gio reais em um barramento
D-Bus privado. O serviço de teste apenas emite respostas/sinais; não executa
operações no sistema. Esses testes precisam de `dbus-daemon` e Python com Gio.

## Espera pelas transações

O helper `lib/transaction.py` mantém uma conexão D-Bus dedicada. Ele instala os
handlers locais e aguarda a resposta de `AddMatch` do barramento antes de
iniciar a operação. Resolve e verifica o proprietário único de `org.lyraos.Vega1`
e chama essa instância, sem redirecionar a chamada para um daemon substituto.
Conclusões anteriores à resposta do método ficam numa fila limitada; depois,
só o ID retornado pode concluir a espera. Sinais de outros IDs são ignorados.

O prazo absoluto de 900 segundos cobre ativação, assinatura, chamada e espera
após abrir a conexão. Cada chamada D-Bus também respeita seu timeout (30 segundos
por padrão). Sinais intercalados não renovam o prazo. Perda do nome do daemon,
reinício, desconexão, timeout ou interrupção encerram a espera e fecham a
conexão, removendo suas assinaturas. Não existe processo de escuta separado.

“Resultado não confirmado” não significa que a operação foi desfeita. O CLI
não repete, cancela ou reverte a operação automaticamente: confira o estado do
sistema antes de tentar novamente. O protocolo atual não oferece consulta
persistente do resultado após reinício do daemon.

AddRepo usa o mesmo mecanismo: só uma chave pendente do mesmo proprietário,
ID e nome de repositório pode abrir a confirmação. O helper aceita os argumentos
string usados pelas transações atuais do CLI (ou nenhum argumento); outras
assinaturas são recusadas antes da conexão. Consultas síncronas seguem usando
`busctl`; os métodos e sinais do contrato não foram alterados.

## Instalação NVIDIA opcional

Em Hardware e Kernel → NVIDIA, consulte o driver e a recuperação sem privilégios. A instalação
exige confirmação explícita e autorização administrativa. Conteúdo novo em
PT/EN/ES; diagnósticos técnicos do backend preservam seus identificadores.
No Web, a senha é revalidada pelo broker PAM/Polkit com o UID real do usuário;
a página acompanha a transação e não confunde aceitação com conclusão.

Requer `nvidia-official-v1` e `nvidia-recovery-v1` (vegad >= 5.1.29). Btrfs usa
Snapper; Server/ext4 simples usa Restic e restauração exclusivamente offline.
O backup deve ser criado e verificado antes do commit. Falha, perda do daemon,
expiração ou interrupção da observação nunca dispara repetição automática.
Veja [o contrato e a recuperação](https://github.com/lyra-os-linux/vegad/blob/main/docs/nvidia.md).
