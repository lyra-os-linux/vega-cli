#!/usr/bin/env bash
# Módulo "Rede e Firewall": interfaces (+ IPv4 estático), proxy global, VPN
# (importar perfil OpenVPN) e serviços do firewall — equivalente ao módulo
# Rede e Firewall do vega-gtk (org.lyraos.Vega1.Network + Firewall,
# vega-gtk/src/ui/network.rs). Sourced pelo entrypoint (bin/vega) — não é
# executável sozinho.
#
# Omissão deliberada (ver critério da issue #110): Wi-Fi (ConnectWifi/
# ListWifi/Disconnect no contrato Network) fica de fora desta versão. O
# vega-cli é pensado pra administração de servidores via SSH, e servidores
# tipicamente não têm rádio Wi-Fi — a tela de Wi-Fi do vega-gtk não tem
# equivalente aqui. Interfaces, proxy, VPN e firewall (o que o critério de
# aceite da issue realmente pede) estão todos implementados.

# vega::network::_validar_ipv4_cidr <endereço/prefixo>
vega::network::_validar_ipv4_cidr() {
  local value="$1" ip prefix
  [[ "$value" == */* ]] || return 1
  ip="${value%%/*}"
  prefix="${value#*/}"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local octet
  for octet in "${BASH_REMATCH[@]:1}"; do
    [ "$octet" -le 255 ] || return 1
  done
  [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -le 32 ]
}

# vega::network::_validar_ipv4 <endereço>
vega::network::_validar_ipv4() {
  local value="$1"
  [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local octet
  for octet in "${BASH_REMATCH[@]:1}"; do
    [ "$octet" -le 255 ] || return 1
  done
}

# ---------------------------------------------------------------------------
# Interfaces

vega::network::_configurar_ipv4() {
  local nome="$1" ipv4_atual="$2" gateway_atual="$3" dns_atual="$4"

  local conexao
  conexao="$(vega::ui::inputbox "Configurar IPv4" "Conexão:" "$nome")" || return
  conexao="$(printf '%s' "$conexao" | xargs)"
  local endereco
  endereco="$(vega::ui::inputbox "Configurar IPv4" "Endereço/CIDR (ex.: 192.168.1.20/24):" "$ipv4_atual")" || return
  local gateway
  gateway="$(vega::ui::inputbox "Configurar IPv4" "Gateway (ex.: 192.168.1.1, opcional):" "$gateway_atual")" || return
  local dns
  dns="$(vega::ui::inputbox "Configurar IPv4" "DNS (ex.: 1.1.1.1, 8.8.8.8, opcional):" "$dns_atual")" || return

  if [ -z "$conexao" ] || ! vega::network::_validar_ipv4_cidr "$endereco"; then
    vega::ui::msgbox "Informe uma conexão e um endereço IPv4 com CIDR válido." "Interfaces"
    return
  fi
  if [ -n "$gateway" ] && ! vega::network::_validar_ipv4 "$gateway"; then
    vega::ui::msgbox "O gateway IPv4 informado é inválido." "Interfaces"
    return
  fi

  vega::ui::yesno "Configurar IPv4 estático?

O NetworkManager substituirá a configuração automática e reconectará esta conexão." \
    "Configurar IPv4 estático?" || return

  vega::ui::infobox "Aplicando IPv4 estático…" "Interfaces"
  if vega::dbus::call Network SetStaticIPv4 ssss "$conexao" "$endereco" "$gateway" "$dns" >/dev/null; then
    vega::ui::msgbox "IPv4 estático aplicado." "Interfaces"
  else
    vega::ui::msgbox "Falha ao configurar IPv4: $VEGA_DBUS_LAST_ERROR" "Interfaces"
  fi
}

vega::network::_interfaces() {
  while true; do
    vega::ui::infobox "Carregando interfaces…" "Rede e Firewall"
    local data rc=0
    data="$(vega::dbus::call_data Network ListInterfaces)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar interfaces: $VEGA_DBUS_LAST_ERROR" "Interfaces"
      return
    fi
    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"
    if [ "$count" -eq 0 ]; then
      vega::ui::msgbox "Nenhuma interface detectada." "Interfaces"
      return
    fi

    local -a names kinds states ipv4s ipv6s gateways dnss macs speeds devices menu_args=()
    local -a rows
    mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] |
      [.[0],.[1],.[2],.[3],.[4],.[5],.[6],.[7],.[8],.[11]] | join("")')
    local idx=0 row name kind state ipv4 ipv6 gateway dns mac speed device
    for row in "${rows[@]}"; do
      IFS=$'\x1f' read -r name kind state ipv4 ipv6 gateway dns mac speed device <<<"$row"
      names[idx]="$name"; kinds[idx]="$kind"; states[idx]="$state"
      ipv4s[idx]="$ipv4"; ipv6s[idx]="$ipv6"; gateways[idx]="$gateway"
      dnss[idx]="$dns"; macs[idx]="$mac"; speeds[idx]="$speed"; devices[idx]="$device"
      menu_args+=("$idx" "$name • $device — $kind • $state • IPv4 ${ipv4:-—}")
      idx=$((idx + 1))
    done
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Interfaces" "Escolha uma interface:" "${menu_args[@]}")" || return
    [ "$choice" = "voltar" ] && return

    vega::ui::msgbox "Conexão: ${names[$choice]}
Dispositivo: ${devices[$choice]}
Tipo: ${kinds[$choice]}
Estado: ${states[$choice]}
IPv4: ${ipv4s[$choice]:-—}
IPv6: ${ipv6s[$choice]:-—}
Gateway: ${gateways[$choice]:-—}
DNS: ${dnss[$choice]:-—}
MAC: ${macs[$choice]}
Velocidade: ${speeds[$choice]:-—}" "${names[$choice]}"

    vega::ui::yesno "Configurar IPv4 estático para \"${names[$choice]}\"?" "Interfaces" || continue
    vega::network::_configurar_ipv4 "${names[$choice]}" "${ipv4s[$choice]}" "${gateways[$choice]}" "${dnss[$choice]}"
  done
}

# ---------------------------------------------------------------------------
# Proxy

vega::network::_proxy() {
  vega::ui::infobox "Carregando configuração de proxy…" "Proxy"
  local data rc=0
  data="$(vega::dbus::call_data Network GetProxy)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao consultar proxy: $VEGA_DBUS_LAST_ERROR" "Proxy"
    return
  fi
  local http https socks no_proxy
  http="$(printf '%s' "$data" | jq -r '.[0][0]')"
  https="$(printf '%s' "$data" | jq -r '.[0][1]')"
  socks="$(printf '%s' "$data" | jq -r '.[0][2]')"
  no_proxy="$(printf '%s' "$data" | jq -r '.[0][3]')"

  local resumo="Proxy não configurado"
  if [ -n "$http$https$socks$no_proxy" ]; then
    resumo="Configuração carregada de /etc/environment"
  fi
  vega::ui::yesno "$resumo

HTTP: ${http:-—}
HTTPS: ${https:-—}
SOCKS: ${socks:-—}
Exceções: ${no_proxy:-—}

Editar configuração de proxy?" "Proxy" || return

  local novo_http novo_https novo_socks novo_no_proxy
  novo_http="$(vega::ui::inputbox "Proxy HTTP" "http://servidor:porta:" "$http")" || return
  novo_https="$(vega::ui::inputbox "Proxy HTTPS" "http://servidor:porta:" "$https")" || return
  novo_socks="$(vega::ui::inputbox "Proxy SOCKS" "socks://servidor:porta:" "$socks")" || return
  novo_no_proxy="$(vega::ui::inputbox "Exceções" "localhost, 127.0.0.1, domínio.local:" "$no_proxy")" || return

  local titulo="Aplicar proxy global?"
  local corpo="A configuração será gravada em /etc/environment e poderá exigir uma nova sessão para alcançar todos os aplicativos."
  if [ -z "$novo_http$novo_https$novo_socks$novo_no_proxy" ]; then
    titulo="Remover configuração de proxy?"
    corpo="As variáveis de proxy gerenciadas pelo Vega serão removidas de /etc/environment."
  fi
  vega::ui::yesno "$corpo" "$titulo" || return

  vega::ui::infobox "Aplicando configuração de proxy…" "Proxy"
  if vega::dbus::call Network SetProxy ssss "$novo_http" "$novo_https" "$novo_socks" "$novo_no_proxy" >/dev/null; then
    vega::ui::msgbox "Configuração de proxy atualizada." "Proxy"
  else
    vega::ui::msgbox "Falha ao aplicar proxy: $VEGA_DBUS_LAST_ERROR" "Proxy"
  fi
}

# ---------------------------------------------------------------------------
# VPN

vega::network::_vpn() {
  local caminho
  caminho="$(vega::ui::inputbox "Importar perfil OpenVPN" "Caminho do arquivo .ovpn:")" || return
  caminho="$(printf '%s' "$caminho" | xargs)"
  if [ -z "$caminho" ]; then
    vega::ui::msgbox "Selecione um arquivo local de perfil OpenVPN." "VPN"
    return
  fi
  case "$caminho" in
  *.ovpn | *.OVPN) ;;
  *)
    vega::ui::msgbox "O perfil deve possuir a extensão .ovpn." "VPN"
    return
    ;;
  esac

  vega::ui::yesno "O NetworkManager importará o perfil:
$caminho

Revise a origem e o conteúdo do arquivo antes de continuar." \
    "Importar perfil OpenVPN?" || return

  vega::ui::infobox "Importando perfil OpenVPN…" "VPN"
  if vega::dbus::call Network ImportVPN s "$caminho" >/dev/null; then
    vega::ui::msgbox "Perfil importado no NetworkManager." "VPN"
  else
    vega::ui::msgbox "Falha ao importar perfil: $VEGA_DBUS_LAST_ERROR" "VPN"
  fi
}

# ---------------------------------------------------------------------------
# Firewall

vega::network::_firewall() {
  while true; do
    vega::ui::infobox "Carregando firewall…" "Firewall"
    local status_data rc=0
    status_data="$(vega::dbus::call_data Firewall Status)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao consultar firewall: $VEGA_DBUS_LAST_ERROR" "Firewall"
      return
    fi
    local services_data
    services_data="$(vega::dbus::call_data Firewall ListServices)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar serviços do firewall: $VEGA_DBUS_LAST_ERROR" "Firewall"
      return
    fi

    local enabled zone estado
    enabled="$(printf '%s' "$status_data" | jq -r '.[0][0]')"
    zone="$(printf '%s' "$status_data" | jq -r '.[0][1]')"
    estado="Inativo"
    [ "$enabled" = "true" ] && estado="Ativo"

    local count
    count="$(printf '%s' "$services_data" | jq -r '.[0] | length')"
    local -a names labels enableds menu_args=()
    if [ "$count" -gt 0 ]; then
      local -a rows
      mapfile -t rows < <(printf '%s' "$services_data" | jq -r '.[0][] | [.[0],.[1],(.[2]|tostring)] | join("")')
      local idx=0 row name label svc_enabled
      for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r name label svc_enabled <<<"$row"
        names[idx]="$name"; labels[idx]="$label"; enableds[idx]="$svc_enabled"
        menu_args+=("$idx" "$label ($name) — $([ "$svc_enabled" = "true" ] && echo "Permitido" || echo "Bloqueado")")
        idx=$((idx + 1))
      done
    fi
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Firewall ($estado • zona/perfil: ${zone:-—})" "Escolha um serviço:" "${menu_args[@]}")" || return
    [ "$choice" = "voltar" ] && return
    if [ "$count" -eq 0 ]; then
      continue
    fi

    local name="${names[$choice]}" label="${labels[$choice]}" was_enabled="${enableds[$choice]}"
    local novo_enabled="true" verbo="Permitir" estado_palavra="permitido"
    if [ "$was_enabled" = "true" ]; then
      novo_enabled="false"
      verbo="Bloquear"
      estado_palavra="bloqueado"
    fi

    vega::ui::yesno "$label ($name) será $estado_palavra nas conexões de entrada." \
      "$verbo serviço no firewall?" || continue

    vega::ui::infobox "Atualizando firewall…" "Firewall"
    if ! vega::dbus::call Firewall SetServiceEnabled sb "$name" "$novo_enabled" >/dev/null; then
      vega::ui::msgbox "Falha ao atualizar firewall: $VEGA_DBUS_LAST_ERROR" "Firewall"
    fi
  done
}

# ---------------------------------------------------------------------------

vega::module_network() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Rede e Firewall" "Escolha uma área:" \
      interfaces "Interfaces" \
      proxy "Proxy" \
      vpn "VPN" \
      firewall "Firewall" \
      voltar "Voltar")" || return

    case "$choice" in
    interfaces) vega::network::_interfaces || true ;;
    proxy) vega::network::_proxy || true ;;
    vpn) vega::network::_vpn || true ;;
    firewall) vega::network::_firewall || true ;;
    voltar | "") return ;;
    esac
  done
}
