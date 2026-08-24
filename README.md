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
