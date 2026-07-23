# Empacotamento para o openSUSE Build Service (home:rodrigosbrito:vega).
# Cópia de packaging/opensuse/vega-cli.spec adaptada só no Source0/%setup
# pra bater com o tarball que o _service (tar_scm) deste mesmo diretório
# gera — nome com sufixo de versão e diretório interno próprio, ao invés
# do tar "achatado" (sem diretório-raiz) que .github/workflows/release-opensuse.yml
# monta com tar czf. Resto do spec é idêntico ao de packaging/opensuse/.
#
# vega-cli é puro shell script (bash + dialog) — sem etapa de compilação,
# BuildArch: noarch e sem makedepends de toolchain.
#
# Version literal (não %%{version}/%%define) — o serviço set_version deste
# diretório faz substituição textual simples na linha "Version:" e não
# entende macro, então precisa achar um valor literal aqui pra reescrever.

Name:           vega-cli
Version:        0
Release:        1%{?dist}
Summary:        Interface de terminal do Vega (dialog) para administração via SSH
License:        GPL-3.0-only
URL:            https://github.com/britors/Vega
Source0:        vega-src-%{version}.tar
BuildArch:      noarch

Requires:       dialog
Requires:       jq
Requires:       systemd
Requires:       polkit
Requires:       sudo

%description
Interface de terminal do Vega (shell + dialog), para administrar
servidores via SSH sem ambiente gráfico. Reaproveita o vegad e o mesmo
contrato D-Bus (org.lyraos.Vega1.*) já usado pelo vega-gtk — só o
frontend é novo.

%prep
%setup -q -n vega-src-%{version}

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

%files
%dir %{_prefix}/lib/vega-cli
%dir %{_prefix}/lib/vega-cli/bin
%dir %{_prefix}/lib/vega-cli/lib
%{_prefix}/lib/vega-cli/bin/vega
%{_prefix}/lib/vega-cli/lib/*.sh
%{_prefix}/lib/vega-cli/lib/theme.dialogrc
%{_bindir}/vega

%changelog
