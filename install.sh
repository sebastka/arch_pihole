#!/bin/bash
set -e
#set -x

#######################################
#	PiHole + OpenVPN + nftables on arch ARMv7
#	Assumes a wired connection on $CONFIG_LAN_INTERFACE
#
#	Arguments:
#		None
#	Returns:
#		1 upon error
#		0 otherwise
#######################################
function main() {
	local readonly USAGE="Usage: install"

	if [[ "${#}" -ne 0 ]]; then
		err "Error: no argument required, ${#} received"
		err "${USAGE}"
		return 1
	fi

	if [ "${EUID}" -ne 0 ]; then
		err "Please run as root"
		return 2
	fi

	if [[ ! -f .env ]]; then
		err "Could not find .env file"
		return 3
	fi

	# Load .env
	set -o allexport && source .env && set +o allexport

	# Make sure we are ready
	cat .env
	warn	"\n\nBefore continuing, please make sure that:\n" \
		"\t- The server is set up with a static local IP (${CONFIG_LAN_IP});\n" \
		"\t- The variables in .env are correct\n"

	# Change default passwords
	echo -e "\nNew password for root:" && passwd root
	echo "New passord for alarm:" && passwd alarm

	# Create new user
	useradd -m -G wheel -s /bin/bash "${CONFIG_USER_NAME}"
	echo "New password for ${CONFIG_USER_NAME}:"
	passwd "${CONFIG_USER_NAME}"

	# Update locale
	locale-gen

	# Get keys, update, install base packages and extra packages
	pacman-key --init
	pacman-key --populate archlinuxarm
	pacman -Syu
	pacman -S --needed sudo base-devel dnsutils git vim cronie wget
	pacman -S --needed ${CONFIG_SYSTEM_EXTRA_PACKAGES}
	install_from_aur ${CONFIG_SYSTEM_EXTRA_PACKAGES_AUR}
	systemctl enable --now cronie

	# Allow members of wheel group to run sudo
	sed -i "s/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/g" /etc/sudoers

	# Configure firewall and sshd (no root login, only pubkey login...)
	setup_sshd
	setup_iptables

	# Install services listed in .env (CONFIG_SYSTEM_SERVICES)
	services_array=($CONFIG_SYSTEM_SERVICES) # String to array
	for s in "${services_array[@]}"; do
		eval "install_${s}"
	done

	# Fetch dotfiles, ssh key, and run extra personal command defined in .env
	warn "\nFinalizing...\n"
	[[ ! -z "${CONFIG_USER_DOTFILES}" ]] && su "${CONFIG_USER_NAME}" -c "cd ~ && git clone ${CONFIG_USER_DOTFILES}"
	[[ ! -z "${CONFIG_USER_COMMAND}" ]] && su "${CONFIG_USER_NAME}" -c "${CONFIG_USER_COMMAND}"
	[[ ! -z "${CONFIG_USER_PRIVKEY}" ]] && su "${CONFIG_USER_NAME}" -c "mkdir -p ~/.ssh && echo -e \"${CONFIG_USER_PRIVKEY}\" > ~/.ssh/${CONFIG_USER_NAME}@${CONFIG_SERVER_HOSTNAME}"

	# Autodownload updates twice a day
	(crontab -l 2>/dev/null; echo "0 0,12 * * * pacman -Syuw --noconfirm") | crontab - # Can be dangerous

	echo -e "\nDone. Please reboot"

	return 0
}

#######################################
#       Install from AUR              #
#######################################
function install_from_aur() {
	[[ "${#}" -lt 1 ]] && return 1
	local readonly packages="${@}"

	for package in ${packages}; do
		# Remove cache
		[[ -d "/home/${CONFIG_USER_NAME}/.cache/paru/clone/${package}" ]] && rm -rf "/home/${CONFIG_USER_NAME}/.cache/paru/clone/${package}"

		# Create package
		su "${CONFIG_USER_NAME}" -c "\
			mkdir -p /home/${CONFIG_USER_NAME}/.cache/paru/clone/ && \
			git clone 'https://aur.archlinux.org/${package}.git/' '/home/${CONFIG_USER_NAME}/.cache/paru/clone/${package}/' && \
			cd '/home/${CONFIG_USER_NAME}/.cache/paru/clone/${package}/' && \
			makepkg --noconfirm -s \
		"

		# Install package
		pacman --noconfirm -U "$(ls /home/${CONFIG_USER_NAME}/.cache/paru/clone/${package}/*.pkg.tar.xz)"
	done

	return 0
}

#######################################
#         Setup sshd                  #
#######################################
function setup_sshd() {
	mv /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
	cp /root/root/etc/ssh/sshd_config /etc/ssh/sshd_config
	vim /etc/ssh/sshd_config

	return 0
}

#######################################
#        Setup iptables               #
#######################################
function setup_iptables() {
	local CONFIG_TRUSTED_NETWORKS="${CONFIG_LAN_NETWORK}"
	[[ ! -z "${CONFIG_OPENVPN_SUBNET}" ]] && CONFIG_TRUSTED_NETWORKS="${CONFIG_TRUSTED_NETWORKS},${CONFIG_OPENVPN_SUBNET}"
	[[ ! -z "${CONFIG_WIREGUARD_SUBNET}" ]] && [[ "${CONFIG_OPENVPN_SUBNET}" != "${CONFIG_WIREGUARD_SUBNET}" ]] && CONFIG_TRUSTED_NETWORKS="${CONFIG_TRUSTED_NETWORKS},${CONFIG_WIREGUARD_SUBNET}"

	env_replace /etc/iptables/iptables.rules

	# Check
	vim /etc/iptables/iptables.rules

	# Restart firewall
	systemctl enable --now iptables

	return 0
}

# Using iptables instead of nftables because of Docker
#######################################
#        Setup nftables               #
#######################################
#function install_nftables() {
#	pacman -S --needed nftables
#
#	# Backup
#	[[ -f /etc/nftables.conf ]] && mv /etc/nftables.conf /etc/nftables.conf.bak
#
#	# Copy config file and replace vars
#	cp /root/root/etc/nftables.conf /etc/nftables.conf
#	env_replace /etc/nftables.conf
#
#	# Fetch vpn config
#	local CONFIG_VPN_SUBNET=""
#	[[ ! -z "${CONFIG_OPENVPN_SUBNET}" ]] && CONFIG_VPN_SUBNET="$(echo ${CONFIG_OPENVPN_SUBNET} | xargs printf "%s" | sed -e 's/[]\/$*.^[]/\\&/g')"
#	[[ ! -z "${CONFIG_WIREGUARD_SUBNET}" ]] && CONFIG_VPN_SUBNET="$(echo ${CONFIG_WIREGUARD_SUBNET} | xargs printf "%s" | sed -e 's/[]\/$*.^[]/\\&/g')"
#	sed -i "s/CONFIG_VPN_SUBNET/${CONFIG_VPN_SUBNET}/g" /etc/nftables.conf
#
#	# Check
#	vim /etc/nftables.conf
#
#	# Restart firewall
#	systemctl enable nftables
#
#	return 0
#}

#######################################
#        Setup OpenVPN                #
#######################################
function install_openvpn() {
	pacman -S --needed openvpn easy-rsa

	# Define env
	export EASYRSA=/etc/easy-rsa
	export EASYRSA_VARS_FILE="${EASYRSA}/vars"

	# Set up Easy-rsa vars
	mv "${EASYRSA_VARS_FILE}" "${EASYRSA_VARS_FILE}.bak"
	echo "set_var EASYRSA_ALGO ec" > "${EASYRSA_VARS_FILE}"
	echo "set_var EASYRSA_CURVE secp521r1" >> "${EASYRSA_VARS_FILE}"
	echo "set_var EASYRSA_DIGEST \"sha512\"" >> "${EASYRSA_VARS_FILE}"
	echo "set_var EASYRSA_NS_SUPPORT \"no\"" >> "${EASYRSA_VARS_FILE}"
	vim "${EASYRSA_VARS_FILE}"

	# Set up CA, keys and crt
	openvpn --genkey secret /etc/openvpn/server/ta.key

	pushd "${EASYRSA}"
	easyrsa init-pki
	easyrsa build-ca
	easyrsa gen-req "${CONFIG_SERVER_HOSTNAME}" nopass
	easyrsa sign-req server "${CONFIG_SERVER_HOSTNAME}"
	easyrsa gen-crl
	popd

	# Copy keys and cert to /etc/openvpn/
	cp	/etc/easy-rsa/pki/ca.crt \
		"/etc/easy-rsa/pki/private/${CONFIG_SERVER_HOSTNAME}.key" \
		"/etc/easy-rsa/pki/issued/${CONFIG_SERVER_HOSTNAME}.crt" \
		/etc/easy-rsa/pki/crl.pem \
		/etc/openvpn/server/
	
	# Fetch openvpn config
	cp /root/root/etc/openvpn/server/server.conf "/etc/openvpn/server/${CONFIG_SERVER_HOSTNAME}.conf"

	# Update config file with env
	env_replace "/etc/openvpn/server/${CONFIG_SERVER_HOSTNAME}.conf"
	
	# Fetching vpn and lan config
	local readonly CONFIG_LAN_NID=$(echo ${CONFIG_LAN_NETWORK} | cut -d'/' -f1 | xargs printf "%s" | sed -e 's/[]\/$*.^[]/\\&/g')
	local readonly CONFIG_LAN_MASK=$(cidr2mask ${CONFIG_LAN_NETWORK} | xargs printf "%s" | sed -e 's/[]\/$*.^[]/\\&/g')
	local readonly CONFIG_OPENVPN_NID=$(echo ${CONFIG_OPENVPN_SUBNET} | cut -d'/' -f1 | xargs printf "%s" | sed -e 's/[]\/$*.^[]/\\&/g')
	local readonly CONFIG_OPENVPN_MASK=$(cidr2mask ${CONFIG_OPENVPN_SUBNET} | xargs printf "%s" | sed -e 's/[]\/$*.^[]/\\&/g')

	# Aplying temp config vars
	sed -i "s/CONFIG_LAN_NID/${CONFIG_LAN_NID}/g" "/etc/openvpn/server/${CONFIG_SERVER_HOSTNAME}.conf"
	sed -i "s/CONFIG_LAN_MASK/${CONFIG_LAN_MASK}/g" "/etc/openvpn/server/${CONFIG_SERVER_HOSTNAME}.conf"
	sed -i "s/CONFIG_OPENVPN_NID/${CONFIG_OPENVPN_NID}/g" "/etc/openvpn/server/${CONFIG_SERVER_HOSTNAME}.conf"
	sed -i "s/CONFIG_OPENVPN_MASK/${CONFIG_OPENVPN_MASK}/g" "/etc/openvpn/server/${CONFIG_SERVER_HOSTNAME}.conf"

	# Check generated config file
	vim "/etc/openvpn/server/${CONFIG_SERVER_HOSTNAME}.conf"

	# Dnsmasq
	mkdir -p /etc/dnsmasq.d/
	echo "interface=tun0" > /etc/dnsmasq.d/00-openvpn.conf

	# Permissions
	mkdir -p /etc/openvpn/revoked/
	chown -R openvpn:network /etc/openvpn/server/ /etc/openvpn/client/ /etc/openvpn/revoked/

	systemctl enable "openvpn-server@${CONFIG_SERVER_HOSTNAME}"

	return 0
}

#######################################
#        Setup Wireguard              #
#######################################
function install_wireguard() {
	## Using systemd-networkd's native WireGuard support
	## https://elou.world/en/tutorial/wireguard
	## https://wiki.archlinux.org/title/WireGuard

	pacman -S --needed wireguard-tools
	mkdir -p /etc/wireguard/

	## Enable IPv4 forwarding (?)
	#sysctl -w net.ipv4.ip_forward=1
	#echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-sysctl.conf

	## Gen "server" peer key pair
	pushd /etc/wireguard/
	umask 137
	wg genkey | tee hermes.private.key | wg pubkey > hermes.public.key
	popd

	# Temp config (Ex: 10.8.0)
	local readonly subnet="$(echo ${CONFIG_WIREGUARD_SUBNET} | cut -d'.' -f1-3)"

	# Config
	echo -e "# WireGurard server peer ${CONFIG_SERVER_HOSTNAME} ${subnet}.1 ${CONFIG_WIREGUARD_SERVERURL}\n\n[NetDev]\nName = wg0\nKind = wireguard\nDescription = WireGurard server peer ${CONFIG_SERVER_HOSTNAME} ${subnet}.1 ${CONFIG_WIREGUARD_SERVERURL}\n\n[WireGuard]\nListenPort = $(echo ${CONFIG_WIREGUARD_SERVERURL} | cut -d':' -f2)\nPrivateKeyFile = /etc/wireguard/${CONFIG_SERVER_HOSTNAME}.private.key" > /etc/systemd/network/99-wg0.netdev
	echo -e "# WireGurard server peer ${CONFIG_SERVER_HOSTNAME} ${subnet}.1 ${CONFIG_WIREGUARD_SERVERURL}\n\n[Match]\nName = wg0\n\n[Network]\nAddress = ${subnet}.1/24\n#DNS = ${CONFIG_WIREGUARD_PEERDNS}\n#DNSDefaultRoute = true\n#Domains = ~.\n\n[Route]\nGateway = ${subnet}.1\nDestination = ${subnet}.0/24\nScope=link" > /etc/systemd/network/99-wg0.network

	## Adjust permissions
	chown -R root:systemd-network /etc/wireguard/ /etc/systemd/network
	chmod -R 640 /etc/systemd/network/*

	return 0
}

#######################################
#        Setup Unbound                #
#######################################
function install_unbound() {
	pacman -S --needed unbound expat

	# Backup old config and fetch ours
	[[ -f /etc/unbound/unbound.conf ]] && mv /etc/unbound/unbound.conf /etc/unbound/unbound.conf.bak
	cp /root/root/etc/unbound/unbound.conf /etc/unbound/unbound.conf
	vim /etc/unbound/unbound.conf

	# Set up service
	echo -e "[Unit]\nDescription=Update root hints for unbound\nAfter=network.target\n\n[Service]\nExecStart=/usr/bin/curl -o /etc/unbound/root.hints https://www.internic.net/domain/named.cache" > /etc/systemd/system/roothints.service
	echo -e "[Unit]\nDescription=Run root.hints monthly\n\n[Timer]\nOnCalendar=monthly\nPersistent=true\n\n[Install]\nWantedBy=timers.target" > /etc/systemd/system/roothints.timer

	# Wait until root.hints is fetched and then start unbound
	systemctl start roothints
	while [ ! -f /etc/unbound/root.hints ]; do sleep 1; done
	systemctl enable --now roothints.timer unbound

	return 0
}

#######################################
#        Setup Docker                 #
#######################################
function install_docker() {
	pacman -S docker docker-compose
	systemctl enable docker # Reboot is needed before it can start
	
	cp -a /root/docker/ "/home/${CONFIG_USER_NAME}/"
	chown -R "${CONFIG_USER_NAME}:${CONFIG_USER_NAME}" "/home/${CONFIG_USER_NAME}/docker/"

	# Extra conf: UID/GID
	local readonly CONFIG_USER_UID=$(id -u "${CONFIG_USER_NAME}")
	local readonly CONFIG_USER_GID=$(id -g "${CONFIG_USER_NAME}")

	# Extra conf: trusted networks
	local CONFIG_TRUSTED_NETWORKS="${CONFIG_LAN_NETWORK}"
	[[ ! -z "${CONFIG_OPENVPN_SUBNET}" ]] && CONFIG_TRUSTED_NETWORKS="${CONFIG_TRUSTED_NETWORKS},${CONFIG_OPENVPN_SUBNET}"
	[[ ! -z "${CONFIG_WIREGUARD_SUBNET}" ]] && [[ "${CONFIG_WIREGUARD_SUBNET}" != "${CONFIG_OPENVPN_SUBNET}" ]] && CONFIG_TRUSTED_NETWORKS="${CONFIG_TRUSTED_NETWORKS},${CONFIG_WIREGUARD_SUBNET}"

	# Update variables update and in each docker-compose.yml
	env_replace "/home/${CONFIG_USER_NAME}/docker/update" "/home/${CONFIG_USER_NAME}/docker/homer/config.yml"

	for f in $(ls -f /home/${CONFIG_USER_NAME}/docker/*/docker-compose.yml); do
		env_replace "${f}"
	done

	# Terminate
	warn "\nAfter reboot, run '~/docker/update x' to get the x container started."
	
	return 0
}

#######################################
#       Div helpers                   #
#######################################

# Replace all placeholders in passed files with values in env
# env_replace my_file.txt my_file2.txt
function env_replace() {
	[[ "${#}" -lt 1 ]] && err "Error: at least argument expected, ${#} received" && return 1

	for f in ${*}; do
		[[ ! -f "${f}" ]] && err "Error: file '${f}' not found" && return 2

		for config_var in "${!CONFIG_@}"; do
			local readonly escaped=$(printf "%s" "${!config_var}"  | sed -e 's/[]\/$*.^[]/\\&/g')
			sed -i "s/${config_var}/${escaped}/g" "${f}"
		done
	done

	return 0
}

# cidre2mask 192.168.1.0/24
# Output: 255.255.255.0
function cidr2mask() {
	[[ "${#}" -ne 1 ]] && return 1
	local readonly bits=$(echo "${1}" | cut -d'/' -f2)

	local readonly masks=("0.0.0.0" "128.0.0.0" "192.0.0.0" "224.0.0.0" "240.0.0.0" "248.0.0.0" "252.0.0.0" "254.0.0.0" "255.0.0.0" "255.128.0.0.0" "255.192.0.0.0" "255.224.0.0.0" "255.240.0.0.0" "255.248.0.0.0" "255.252.0.0.0" "255.254.0.0.0" "255.255.0.0.0" "255.255.128.0" "255.255.192.0" "255.255.224.0" "255.255.240.0" "255.255.248.0" "255.255.252.0" "255.255.254.0" "255.255.255.0" "255.255.255.128" "255.255.255.192" "255.255.255.224" "255.255.255.240" "255.255.255.248" "255.255.255.252" "255.255.255.254" "255.255.255.255")

	echo "${masks[$bits]}"
}

function warn() {
	echo -e "${*}"
	echo -n "Press any key to continue or ^C to abort."
	read -s -n 1 key
}

# Print to stderr (from Google)
function err() {
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: ${*}" >&2
}

# Functions to run with su
export -f install_from_aur

main "${@}"; exit
