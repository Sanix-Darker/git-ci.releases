#!/bin/sh
# GCI installer v2: download, verify, install, then exec `gci up` with every
# other argument. All setup (service, user, Docker, runner, Caddy) is in gci up.
set -eu

repository='Sanix-Darker/git-ci.releases'
release_base=${GCI_RELEASE_BASE_URL:-https://github.com/$repository/releases/download}
latest_url=${GCI_LATEST_URL:-https://github.com/$repository/releases/latest}
version=''
install_dir=${GCI_INSTALL_DIR:-}
no_up=0
user_agent=${GCI_INSTALL_USER_AGENT:-}

usage() {
	cat <<'EOF'
Install GCI from the public checksummed release repository, then run gci up.

Usage: install.sh [--version V] [--install-dir D] [--no-up] [gci up arguments...]

  --version VERSION   Install an exact release, for example v0.70.0 (default: latest)
  --install-dir DIR   Binary directory (default: /usr/local/bin as root, else ~/.local/bin)
  --no-up             Install the binary only
  -h, --help          Show this help

Every other argument goes to `gci up`, for example:
  install.sh https://gitlab.com glrt-XXXXXXXX
  install.sh --project /srv/projects/app --domain ci.example.com

Accepted for compatibility: --system, --service, --upgrade, --with-docker
(no-ops: gci up decides) and --port P (passed on as --listen 127.0.0.1:P).
A license key is read only from the GCI_LICENSE_KEY environment variable.
Downloads say User-Agent: gci-installer/<version>; GCI_INSTALL_USER_AGENT
replaces it for a network that needs another value.
The installer never prompts.
EOF
}

die() {
	printf 'gci install: %s\n' "$*" >&2
	exit 1
}

info() {
	printf 'gci install: %s\n' "$*"
}

# Own flags are consumed; everything else is re-appended to "$@" for gci up.
n=$#
while [ "$n" -gt 0 ]; do
	arg=$1
	shift
	n=$((n - 1))
	case "$arg" in
		--version|--install-dir|--port)
			[ "$n" -gt 0 ] || die "$arg needs a value"
			value=$1
			shift
			n=$((n - 1))
			case "$arg" in
				--version) version=$value ;;
				--install-dir) install_dir=$value ;;
				--port)
					case "$value" in ''|*[!0-9]*) die 'port must be numeric' ;; esac
					set -- "$@" --listen "127.0.0.1:$value"
					;;
			esac
			;;
		--no-up) no_up=1 ;;
		--system|--service|--upgrade) info "$arg is no longer needed (gci up decides); ignored" ;;
		--with-docker) info '--with-docker is automatic when installing as root; ignored' ;;
		-h|--help) usage; exit 0 ;;
		*) set -- "$@" "$arg" ;;
	esac
done

if [ -n "${GCI_LICENSE_KEY:-}" ]; then
	case "$GCI_LICENSE_KEY" in *'
'*) die 'GCI_LICENSE_KEY must not contain a newline' ;; esac
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
		effective=$(curl -A "${user_agent:-gci-installer/latest}" -fsSLI --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' "$latest_url")
		version=${effective##*/}
	fi
fi
case "$version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) die "invalid release version: $version" ;; esac
case "$version" in *[!A-Za-z0-9._-]*) die "invalid release version: $version" ;; esac
[ -n "$user_agent" ] || user_agent="gci-installer/$version"

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

if [ -z "$install_dir" ]; then
	if [ "$(id -u)" -eq 0 ]; then install_dir=/usr/local/bin; else install_dir=$HOME/.local/bin; fi
fi
install -d -m 0755 "$install_dir"
install -m 0755 "$temporary/$binary" "$install_dir/.gci.new"
mv -f "$install_dir/.gci.new" "$install_dir/gci"
info "installed $version at $install_dir/gci"

if [ "$no_up" -eq 1 ]; then
	# Without gci up, say here what gci up's summary says otherwise (E4).
	case ":${PATH:-}:" in
		*":$install_dir:"*) ;;
		*)
			shown=$install_dir
			[ "$install_dir" != "$HOME/.local/bin" ] || shown='$HOME/.local/bin'
			info "$install_dir is not on PATH: this shell runs it as $install_dir/gci; to shorten it, add to your shell profile: export PATH=\"$shown:\$PATH\""
			;;
	esac
	exit 0
fi
cleanup
trap - EXIT HUP INT TERM
exec "$install_dir/gci" up "$@"
