#!/bin/sh
set -eu

repository='Sanix-Darker/git-ci.releases'
release_base=${GCI_RELEASE_BASE_URL:-https://github.com/$repository/releases/download}
latest_url=${GCI_LATEST_URL:-https://github.com/$repository/releases/latest}
version=''
system_install=0
service_install=0
with_docker=0
upgrade=0
repo_url=''
domain=''
listen_port=''
install_dir=${GCI_INSTALL_DIR:-}
state_dir=${GCI_STATE_DIR:-/var/lib/git-ci}
projects_root=${GCI_PROJECTS_ROOT:-/srv/projects}
service_user=${GCI_SERVICE_USER:-git-ci}
user_agent='OpenAI File Downloader, XaiImageApiFetch/1.0'

usage() {
	cat <<'EOF'
Install GCI from the public checksummed release repository.

Usage: install.sh [options]

  --version VERSION   Install an exact release, for example v0.47.6
  --upgrade           Replace an existing binary with the selected/latest release
  --system            Install /usr/local/bin/gci (requires root or sudo)
  --service           Install and start the systemd service; implies --system
  --repo URL          Clone one Git repository below /srv/projects after service setup
  --with-docker       Explicitly install/enable the OS Docker package
  --domain DOMAIN     Add a Caddy reverse-proxy route when Caddy is already installed
  --port PORT         Service origin port (default: first available from 8087)
  --install-dir DIR   Override the user or system binary directory
  -h, --help          Show this help

License keys are accepted only through GCI_LICENSE_KEY or a later hidden prompt.
They are never accepted as command arguments.
EOF
}

die() {
	printf 'gci install: %s\n' "$*" >&2
	exit 1
}

info() {
	printf 'gci install: %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--version)
			[ "$#" -ge 2 ] || die '--version needs a value'
			version=$2
			shift 2
			;;
		--upgrade) upgrade=1; shift ;;
		--system) system_install=1; shift ;;
		--service) service_install=1; system_install=1; shift ;;
		--with-docker) with_docker=1; shift ;;
		--repo)
			[ "$#" -ge 2 ] || die '--repo needs a value'
			repo_url=$2
			shift 2
			;;
		--domain)
			[ "$#" -ge 2 ] || die '--domain needs a value'
			domain=$2
			shift 2
			;;
		--port)
			[ "$#" -ge 2 ] || die '--port needs a value'
			listen_port=$2
			shift 2
			;;
		--install-dir)
			[ "$#" -ge 2 ] || die '--install-dir needs a value'
			install_dir=$2
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -z "$repo_url" ] || [ "$service_install" -eq 1 ] || die '--repo requires --service'
[ -z "$domain" ] || [ "$service_install" -eq 1 ] || die '--domain requires --service'
if [ -n "${GCI_LICENSE_KEY:-}" ]; then
	case "$GCI_LICENSE_KEY" in *'
'*) die 'GCI_LICENSE_KEY must not contain a newline' ;; esac
fi

case "$domain" in
	'' ) ;;
	*[!A-Za-z0-9.-]*|.*|*.) die 'domain is invalid' ;;
esac
case "$listen_port" in
	'' ) ;;
	*[!0-9]*) die 'port must be numeric' ;;
esac
if [ -n "$listen_port" ] && { [ "$listen_port" -lt 1024 ] || [ "$listen_port" -gt 65535 ]; }; then
	die 'port must be between 1024 and 65535'
fi

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v tar >/dev/null 2>&1 || die 'tar is required'

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in linux|darwin) ;; *) die "unsupported operating system: $os" ;; esac
machine=$(uname -m)
case "$machine" in
	x86_64|amd64) arch=amd64 ;;
	aarch64|arm64) arch=arm64 ;;
	*) die "unsupported architecture: $machine" ;;
esac
[ "$service_install" -eq 0 ] || [ "$os" = linux ] || die '--service supports Linux only'

download() {
	source_url=$1
	destination=$2
	case "$source_url" in
		https://*) ;;
		file://*) [ "${GCI_INSTALLER_TEST:-0}" = 1 ] || die 'file release URLs are test-only' ;;
		*) die 'release URL must use HTTPS' ;;
	esac
	curl -A "$user_agent" -fsSL --proto '=https,file' --tlsv1.2 "$source_url" -o "$destination"
}

if [ -z "$version" ]; then
	if [ -n "${GCI_LATEST_VERSION:-}" ]; then
		version=$GCI_LATEST_VERSION
	else
		effective=$(curl -A "$user_agent" -fsSLI --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' "$latest_url")
		version=${effective##*/}
	fi
fi
case "$version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) die "invalid release version: $version" ;; esac
case "$version" in *[!A-Za-z0-9._-]*) die "invalid release version: $version" ;; esac

asset="gci-$version-$os-$arch.tar.gz"
binary="gci-$os-$arch"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/gci-install.XXXXXX")
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT HUP INT TERM
umask 077

info "downloading $asset"
download "$release_base/$version/$asset" "$temporary/$asset"
download "$release_base/$version/checksums.txt" "$temporary/checksums.txt"
expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$temporary/checksums.txt")
[ -n "$expected" ] || die "checksum entry is missing for $asset"
case "$expected" in *[!0-9a-fA-F]*|'') die 'release checksum is invalid' ;; esac
[ "${#expected}" -eq 64 ] || die 'release checksum must be SHA-256'
if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$temporary/$asset" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$temporary/$asset" | awk '{print $1}')
else
	die 'sha256sum or shasum is required'
fi
[ "$actual" = "$expected" ] || die "checksum mismatch for $asset"

tar -xzf "$temporary/$asset" -C "$temporary"
[ -f "$temporary/$binary" ] || die "archive does not contain $binary"
chmod 0755 "$temporary/$binary"

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		die 'root privileges are required; install sudo or run as root'
	fi
}

if [ -z "$install_dir" ]; then
	if [ "$system_install" -eq 1 ]; then install_dir=/usr/local/bin; else install_dir=$HOME/.local/bin; fi
fi
if [ "$system_install" -eq 1 ]; then
	as_root install -d -m 0755 "$install_dir"
	as_root install -m 0755 "$temporary/$binary" "$install_dir/.gci.new"
	as_root mv -f "$install_dir/.gci.new" "$install_dir/gci"
else
	install -d -m 0755 "$install_dir"
	install -m 0755 "$temporary/$binary" "$install_dir/.gci.new"
	mv -f "$install_dir/.gci.new" "$install_dir/gci"
fi
info "installed $version at $install_dir/gci"
[ "$upgrade" -eq 0 ] || info 'upgrade completed'

if [ "$with_docker" -eq 1 ]; then
	[ "$os" = linux ] || die '--with-docker supports Linux only'
	if ! command -v docker >/dev/null 2>&1; then
		if command -v apt-get >/dev/null 2>&1; then
			as_root apt-get update
			as_root apt-get install -y docker.io
		elif command -v dnf >/dev/null 2>&1; then
			as_root dnf install -y docker
		elif command -v yum >/dev/null 2>&1; then
			as_root yum install -y docker
		else
			die 'no supported package manager found for Docker installation'
		fi
	fi
	as_root systemctl enable --now docker
	info 'Docker is installed and enabled'
fi

port_in_use() {
	port=$1
	if command -v ss >/dev/null 2>&1; then
		ss -ltn | awk '{print $4}' | awk -F: -v port="$port" '$NF == port { found=1 } END { exit !found }'
	elif command -v netstat >/dev/null 2>&1; then
		netstat -ltn | awk '{print $4}' | awk -F: -v port="$port" '$NF == port { found=1 } END { exit !found }'
	else
		return 1
	fi
}

if [ "$service_install" -eq 1 ]; then
	command -v systemctl >/dev/null 2>&1 || die 'systemd is required for --service'
	if [ -z "$listen_port" ]; then
		listen_port=8087
		while port_in_use "$listen_port"; do
			listen_port=$((listen_port + 1))
			[ "$listen_port" -le 8187 ] || die 'no available service port found between 8087 and 8187'
		done
	elif port_in_use "$listen_port"; then
		die "port $listen_port is already in use"
	fi

	if ! id "$service_user" >/dev/null 2>&1; then
		as_root useradd --system --home-dir "$state_dir" --create-home --shell /usr/sbin/nologin "$service_user"
	fi
	as_root install -d -m 0750 -o "$service_user" -g "$service_user" "$state_dir" "$projects_root"
	as_root install -d -m 0750 /etc/git-ci
	env_file=$temporary/git-ci.env
	cat >"$env_file" <<EOF
GIT_CI_LISTEN=127.0.0.1:$listen_port
GIT_CI_STATE_DIR=$state_dir
GIT_CI_PROJECTS_ROOT=$projects_root
EOF
	if [ -n "${GCI_LICENSE_KEY:-}" ]; then
		printf 'GCI_LICENSE_KEY=%s\n' "$GCI_LICENSE_KEY" >>"$env_file"
	fi
	as_root install -m 0600 -o root -g "$service_user" "$env_file" /etc/git-ci/git-ci.env
	unit_file=$temporary/git-ci.service
	cat >"$unit_file" <<EOF
[Unit]
Description=GCI private CI/CD service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$service_user
Group=$service_user
EnvironmentFile=/etc/git-ci/git-ci.env
ExecStart=$install_dir/gci serve --listen \${GIT_CI_LISTEN} --state-dir \${GIT_CI_STATE_DIR} --projects-root \${GIT_CI_PROJECTS_ROOT}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=read-only
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
	as_root install -m 0644 "$unit_file" /etc/systemd/system/git-ci.service
	if [ "$with_docker" -eq 1 ] && getent group docker >/dev/null 2>&1; then
		as_root usermod -aG docker "$service_user"
	fi
	as_root systemctl daemon-reload
	as_root systemctl enable --now git-ci.service
	info "service is running at 127.0.0.1:$listen_port"

	if [ -n "$repo_url" ]; then
		command -v git >/dev/null 2>&1 || die 'git is required for --repo'
		repo_name=${repo_url##*/}
		repo_name=${repo_name%.git}
		case "$repo_name" in ''|*[!A-Za-z0-9._-]*) die 'repository name is unsafe' ;; esac
		destination=$projects_root/$repo_name
		[ ! -e "$destination" ] || die "repository destination already exists: $destination"
		if [ "$(id -u)" -eq 0 ]; then
			command -v runuser >/dev/null 2>&1 || die 'runuser is required to clone as the service account'
			runuser -u "$service_user" -- git clone -- "$repo_url" "$destination"
		else
			sudo -u "$service_user" git clone -- "$repo_url" "$destination"
		fi
		info "cloned repository at $destination"
	fi

	if [ -n "$domain" ]; then
		command -v caddy >/dev/null 2>&1 || die '--domain requires an existing Caddy installation'
		caddy_snippet=$temporary/gci.caddy
		cat >"$caddy_snippet" <<EOF
$domain {
	reverse_proxy 127.0.0.1:$listen_port
}
EOF
		as_root install -m 0644 "$caddy_snippet" /etc/caddy/gci.caddy
		if ! as_root sh -c "grep -Fqx 'import /etc/caddy/gci.caddy' /etc/caddy/Caddyfile"; then
			as_root sh -c "printf '\nimport /etc/caddy/gci.caddy\n' >> /etc/caddy/Caddyfile"
		fi
	as_root caddy validate --config /etc/caddy/Caddyfile
		as_root systemctl reload caddy
		info "Caddy route configured for https://$domain"
	fi
fi

case ":$PATH:" in *":$install_dir:"*) ;; *) info "add $install_dir to PATH" ;; esac
