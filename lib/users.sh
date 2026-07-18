#!/usr/bin/env bash
# Módulo "Usuários": listar contas, criar, remover, promover/rebaixar
# administrador — equivalente ao módulo Usuários do vega-gtk
# (org.lyraos.Vega1.Users, vega-gtk/src/ui/users.rs +
# vega-gtk/src/application.rs `configure_users`). Sourced pelo entrypoint
# (bin/vega) — não é executável sozinho.
#
# A conta "root" é sempre imutável aqui (nem remover, nem trocar admin),
# espelhando `mutable = username != "root"` do vega-gtk.

# vega::users::_validar_username <nome>
# Mesma regra de validação do formulário do vega-gtk (front-end): começa
# com letra minúscula ou "_", resto minúsculas/dígitos/"_"/"-". O vegad tem
# uma regra um pouco mais permissiva (aceita "$" no final, pra contas de
# sistema) mas essa tela só cria contas normais, então replica a do GTK.
vega::users::_validar_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

vega::users::_criar() {
  local username
  username="$(vega::ui::inputbox "Novo usuário" "Nome de usuário:")" || return
  username="$(printf '%s' "$username" | xargs)"
  if ! vega::users::_validar_username "$username"; then
    vega::ui::msgbox "Nome de usuário inválido. Use letras minúsculas, dígitos, \"_\" ou \"-\", começando com letra minúscula ou \"_\"." "Usuários"
    return
  fi

  local is_admin role
  if vega::ui::yesno "Criar \"$username\" como administrador?" "Novo usuário"; then
    is_admin="true"
    role="administrador"
  else
    is_admin="false"
    role="usuário comum"
  fi

  vega::ui::yesno "A conta $username será criada como $role." "Criar usuário?" || return

  vega::ui::infobox "Criando $username…" "Usuários"
  if vega::dbus::call Users CreateUser sb "$username" "$is_admin" >/dev/null; then
    vega::ui::msgbox "Usuário $username criado." "Usuários"
  else
    vega::ui::msgbox "Falha ao criar usuário: $VEGA_DBUS_LAST_ERROR" "Usuários"
  fi
}

vega::users::_remover() {
  local username="$1"
  vega::ui::yesno "A conta $username e seu diretório pessoal serão removidos." \
    "Remover usuário?" || return

  vega::ui::infobox "Removendo $username…" "Usuários"
  if vega::dbus::call Users RemoveUser s "$username" >/dev/null; then
    vega::ui::msgbox "Usuário $username removido." "Usuários"
  else
    vega::ui::msgbox "Falha ao remover: $VEGA_DBUS_LAST_ERROR" "Usuários"
  fi
}

vega::users::_alterar_admin() {
  local username="$1" is_admin="$2"
  local novo_admin="true" titulo msg confirm_label
  if [ "$is_admin" = "true" ]; then
    novo_admin="false"
    titulo="Remover privilégios administrativos?"
    msg="$username deixará de administrar o sistema."
  else
    titulo="Conceder privilégios administrativos?"
    msg="$username poderá administrar o sistema."
  fi

  vega::ui::yesno "$msg" "$titulo" || return

  vega::ui::infobox "Processando $username…" "Usuários"
  if vega::dbus::call Users SetAdmin sb "$username" "$novo_admin" >/dev/null; then
    vega::ui::msgbox "Conta $username atualizada." "Usuários"
  else
    vega::ui::msgbox "Falha ao atualizar administração: $VEGA_DBUS_LAST_ERROR" "Usuários"
  fi
}

# vega::users::_acoes_usuario <username> <is_admin ("true"/"false")>
vega::users::_acoes_usuario() {
  local username="$1" is_admin="$2"
  if [ "$username" = "root" ]; then
    vega::ui::msgbox "A conta root não pode ser removida nem ter sua administração alterada por aqui." "Usuários"
    return
  fi

  local admin_label="Tornar admin"
  [ "$is_admin" = "true" ] && admin_label="Remover admin"

  local choice
  choice="$(vega::ui::menu "$username" \
    "$([ "$is_admin" = "true" ] && echo "Administrador" || echo "Usuário comum")" \
    admin "$admin_label" \
    remover "Remover" \
    voltar "Voltar")" || return

  case "$choice" in
  admin) vega::users::_alterar_admin "$username" "$is_admin" ;;
  remover) vega::users::_remover "$username" ;;
  esac
}

vega::module_users() {
  while true; do
    vega::ui::infobox "Carregando usuários…" "Usuários"
    local data rc=0
    data="$(vega::dbus::call_data Users ListUsers)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar usuários: $VEGA_DBUS_LAST_ERROR" "Usuários"
      return
    fi

    local -a menu_args=(novo "+ Criar usuário")
    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"
    local -a usernames=() admins=()
    if [ "$count" -gt 0 ]; then
      local -a rows
      mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] | [.[0],(.[1]|tostring)] | join("")')
      local row username is_admin idx=0
      for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r username is_admin <<<"$row"
        usernames[idx]="$username"
        admins[idx]="$is_admin"
        menu_args+=("$idx" "$username ($([ "$is_admin" = "true" ] && echo "Administrador" || echo "Usuário comum"))")
        idx=$((idx + 1))
      done
    fi
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Usuários" "Escolha uma opção:" "${menu_args[@]}")" || return

    case "$choice" in
    novo) vega::users::_criar || true ;;
    voltar | "") return ;;
    *) vega::users::_acoes_usuario "${usernames[$choice]}" "${admins[$choice]}" || true ;;
    esac
  done
}
