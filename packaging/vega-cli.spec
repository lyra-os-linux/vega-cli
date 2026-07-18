# Empacotamento Linux. Ver vegad.spec neste
# mesmo diretório para as notas gerais (versionamento via --define version,
# status do empacotamento).
#
# vega-cli é puro shell script (bash + dialog) — sem etapa de compilação,
# BuildArch: noarch e sem makedepends de toolchain.
%{!?version: %define version 0.0.0}

Name:           vega-cli
Version:        %{version}
Release:        1%{?dist}
Summary:        Interface de terminal do Vega (dialog) para administração via SSH
License:        GPL-3.0-only
URL:            https://github.com/britors/Vega
Source0:        vega-src.tar.gz
BuildArch:      noarch

Requires:       dialog
Requires:       jq
Requires:       systemd
Requires:       polkit

%description
Interface de terminal do Vega (shell + dialog), para administrar
servidores via SSH sem ambiente gráfico. Reaproveita o vegad e o mesmo
contrato D-Bus (org.lyraos.Vega1.*) já usado pelo vega-gtk — só o
frontend é novo.

%prep
%setup -q -c -n vega-src

%build
# Mesmo mecanismo do -ldflags do vegad: a versão real da release substitui
# o placeholder "0.1.0-dev" só no momento do empacotamento.
sed -i "s/^VEGA_CLI_VERSION=.*/VEGA_CLI_VERSION=\"%{version}\"/" vega-cli/bin/vega

%install
install -Dm755 vega-cli/bin/vega %{buildroot}%{_prefix}/lib/vega-cli/bin/vega
install -d %{buildroot}%{_prefix}/lib/vega-cli/lib
install -m644 vega-cli/lib/*.sh %{buildroot}%{_prefix}/lib/vega-cli/lib/
install -m644 vega-cli/lib/theme.dialogrc %{buildroot}%{_prefix}/lib/vega-cli/lib/theme.dialogrc

# /usr/bin/vega é um symlink pro script real — vega::resolve_root
# (bin/vega) segue o symlink e resolve VEGA_CLI_ROOT a partir do caminho
# real, achando lib/ como irmã de bin/.
install -d %{buildroot}%{_bindir}
ln -s %{_prefix}/lib/vega-cli/bin/vega %{buildroot}%{_bindir}/vega

install -Dm644 packaging/vega-cli/vega-cli.desktop \
    %{buildroot}%{_datadir}/applications/vega-cli.desktop
install -Dm644 packaging/vega-cli/vega-cli.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/vega-cli.svg

%files
%{_prefix}/lib/vega-cli/bin/vega
%{_prefix}/lib/vega-cli/lib/*.sh
%{_prefix}/lib/vega-cli/lib/theme.dialogrc
%{_bindir}/vega
%{_datadir}/applications/vega-cli.desktop
%{_datadir}/icons/hicolor/scalable/apps/vega-cli.svg

%changelog
