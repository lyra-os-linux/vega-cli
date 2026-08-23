# Empacotamento manual para Linux, a partir de um tarball "achatado" do
# próprio repositório (sem diretório de nível superior) — ver
# packaging/vega-cli.obs.spec para a variante consumida pelo OBS via
# tar_scm. Versionamento via --define version (ver Version abaixo).
#
# vega-cli é puro shell script (bash + dialog) — sem etapa de compilação,
# BuildArch: noarch e sem makedepends de toolchain.
%{!?version: %define version 0.0.0}

Name:           vega-cli
Version:        %{version}
Release:        1%{?dist}
Summary:        Interface de terminal do Vega (dialog) para administração via SSH
License:        GPL-3.0-only
URL:            https://github.com/lyra-os-linux/vega-cli
Source0:        vega-cli-src.tar.gz
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
%setup -q -c -n vega-cli-src

%build
# Mesmo mecanismo do -ldflags do vegad: a versão real da release substitui
# o placeholder "0.1.0-dev" só no momento do empacotamento.
sed -i "s/^VEGA_CLI_VERSION=.*/VEGA_CLI_VERSION=\"%{version}\"/" bin/vega

%install
install -Dm755 bin/vega %{buildroot}%{_prefix}/lib/bin/vega
install -d %{buildroot}%{_prefix}/lib/vega-cli/lib
install -m644 lib/*.sh %{buildroot}%{_prefix}/lib/lib/
install -m644 lib/theme.dialogrc %{buildroot}%{_prefix}/lib/lib/theme.dialogrc

# /usr/bin/vega é um symlink pro script real — vega::resolve_root
# (bin/vega) segue o symlink e resolve VEGA_CLI_ROOT a partir do caminho
# real, achando lib/ como irmã de bin/.
install -d %{buildroot}%{_bindir}
ln -s %{_prefix}/lib/bin/vega %{buildroot}%{_bindir}/vega

%files
%dir %{_prefix}/lib/vega-cli
%dir %{_prefix}/lib/vega-cli/bin
%dir %{_prefix}/lib/vega-cli/lib
%{_prefix}/lib/bin/vega
%{_prefix}/lib/lib/*.sh
%{_prefix}/lib/lib/theme.dialogrc
%{_bindir}/vega

%changelog
