#!/bin/bash

LANG=C
PROG=${0##*/}

# ==============================================================================
# Global variables
# ==============================================================================
KRB_CONF=/etc/krb5.conf
SMB_CONF=/etc/samba/smb.conf
HOSTS_CONF=/etc/hosts
RESOLV_CONF=/etc/resolv.conf
HOSTNAME_CONF=/etc/hostname
SSSD_CONF=/etc/sssd/sssd.conf

# ==============================================================================
# Functions
# ==============================================================================
gen_netbios_name() {
	random=$(date | md5sum)
	echo "${HOSTNAME:0:5}-${random:0:5}"
}

cleanup() {
	local admin=$1
	local pass=$2

	if ! net ads leave -U ${admin}%${pass}; then
		echo "Failed to leave domain"
		exit 1
	fi
}

# ==============================================================================
# Parameters processing
# ==============================================================================
Usage() {
cat <<END
Usage: $PROG [OPTION]...

	-h|--help			# Print this help

	-i|--addc-ip <IP>		# Specify IP of a Windows AD DC for target AD DS Domain
	-c|--cleanup			# Leave AD Domain and delete entry in AD database

	-e|--enctype <DES|AES>    	# Choose enctype for Kerberos TGT and TGS instead of default
	-p|--password <password>     	# Specify password of Administrator@Domain instead of default

	--config-krb			# Config current client as a Secure NFS client
	--config-idmap			# Config current client as an NFSv4 IDMAP client
	--root-dc <IP>			# root DC ip
	...
	TBD
END
}

ARGS=$(getopt -o hi:ce:p: \
	--long help \
	--long addc-ip: \
	--long cleanup \
	--long enctype: \
	--long password: \
	--long setspn: \
	--long config-idmap \
	--long root-dc: \
	-a -n "$PROG" -- "$@")
eval set -- "$ARGS"
while true; do
	case "$1" in
	-h|--help) Usage; exit 1;;
	-i|--addc-ip) ADDC_IP="$2"; shift 2;;
	-c|--cleanup) CLEANUP="yes"; shift 1;;
	-e|--enctype) ENCRYPT="$2"; shift 2;;
	-p|--password) PASSWD="$2"; shift 2;;
	--setspn) SPNs="$2"; shift 2;;
	--config-idmap) CONF_IDMAP="yes"; shift 1;;
	--root-dc) ROOT_DC="$2"; shift 2;;
	--) shift; break;;
	*) Usage; exit 1;;
	esac
done

if [[ "$CLEANUP" = "yes" ]]; then
	cleanup Administrator ${PASSWD}
	exit 1
elif [[ -z "$ADDC_IP" || -z "$PASSWD" ]]; then
	echo "Missing --addc-ip or --password parameters."
	Usage
	exit 1
fi

# ==============================================================================
# Check whether the connection works
# ==============================================================================
ping -c 3 "$ADDC_IP"
if [[ "$#" -ne 0 ]]; then
	echo "Can not connect to AD domain"
	exit 1
fi

# ==============================================================================
# Get domain controller infomation
# ==============================================================================
AD_INFO="$(adcli info --domain-controller=${ADDC_IP})"
ADDC_FQDN=$(echo "$AD_INFO" | awk '/domain-controller =/{print $NF}' | tr a-z A-Z);
ADDC_NETBIOS=${ADDC_FQDN%%.*};

DOMAIN_NAME=$(echo "$AD_INFO" | awk '/domain-name =/{print $NF}' | tr a-z A-Z);
DOMAIN_SHORT=$(echo "$AD_INFO" | awk '/domain-short =/{print $NF}' | tr a-z A-Z);

if [[ -z "$ADDC_FQDN" || -z "$ADDC_NETBIOS" || -z "$DOMAIN_NAME" || -z "$DOMAIN_SHORT" ]]; then
	echo "Error when getting information from domain controller"
	exit 1
fi

echo "ADDC_FQDN=$ADDC_FQDN"
echo "ADDC_NETBIOS=$ADDC_NETBIOS"
echo "DOMAIN_NAME=$DOMAIN_NAME"
echo "DOMAIN_SHORT=$DOMAIN_SHORT"

# ==============================================================================
# Join domain
# ==============================================================================
# Clean stale configuration
kdestroy -A
\rm -f /etc/krb5.keytab
\rm -f /tmp/krb5cc*  /var/tmp/krb5kdc_rcache  /var/tmp/rc_kadmin_0

# Use short hostname to satisfy NBNS standard in Windows Domain (RFC 1002)...
NBNS_NAME=$(gen_netbios_name)
hostnamectl set-hostname $NBNS_NAME
echo ${NBNS_NAME} > $HOSTNAME_CONF
echo "$ cat $HOSTNAME_CONF"
cat $HOSTNAME_CONF

# Use Active domain controller as DNS server
echo -e "[main]\ndns=none" >/etc/NetworkManager/NetworkManager.conf
mv $RESOLV_CONF $RESOLV_CONF.orig
{
	echo "search $DOMAIN_NAME"
	[[ -n "$ROOT_DC" ]] && echo "nameserver $ROOT_DC"
	echo "nameserver $ADDC_IP";
} >$RESOLV_CONF
echo "cat $RESOLV_CONF"
cat $RESOLV_CONF

# Shutdown firewall
[ -f /etc/init.d/iptables ] && service iptables stop
which systemctl &>/dev/null && systemctl stop firewalld

# Add IP to FQDN mapping
echo "$ADDC_IP $ADDC_NETBIOS $ADDC_FQDN" >> $HOSTS_CONF
echo "$ cat $HOSTS_CONF"
cat $HOSTS_CONF

krb5_client_conf() {
	local realm=$1
	local kdc=$2
	local encrypt=$3

	# Configure /etc/krb5.conf
	cat <<-EOF >$KRB_CONF
	[logging]
	  default = FILE:/var/log/krb5libs.log

	[libdefaults]
	  default_realm = $realm
	  dns_lookup_realm = true
	  dns_lookup_kdc = true
	  ticket_lifetime = 24h
	  renew_lifetime = 7d
	  forwardable = true
	  rdns = false

	[realms]
	  $realm = {
	    kdc = $kdc
	    admin_server = $kdc
	    default_domain = $kdc
	  }

	[domain_realm]
	  .$kdc = .$realm
	  $kdc = $realm
	EOF

	if [ "$ENCRYPT" == "DES" ]; then
		sed -i -e '/libdefaults/{s/$/\n  default_tgs_enctypes = arcfour-hmac-md5 rc4-hmac des-cbc-crc des-cbc-md5/}'  $KRB_CONF
		sed -i -e '/libdefaults/{s/$/\n  default_tkt_enctypes = arcfour-hmac-md5 rc4-hmac des-cbc-crc des-cbc-md5/}'  $KRB_CONF
		sed -i -e '/libdefaults/{s/$/\n  permitted_enctypes = arcfour-hmac-md5 rc4-hmac des-cbc-crc des-cbc-md5/}'    $KRB_CONF
		sed -i -e '/libdefaults/{s/$/\n  allow_weak_crypto = true/}' $KRB_CONF
		echo "{Info} Kerberos will choose from DES enctypes to select one for TGT and TGS procedures"
	elif [ "$ENCRYPT" == "AES" ]; then
		sed -i -e '/libdefaults/{s/$/\n  default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96/}'  $KRB_CONF
		sed -i -e '/libdefaults/{s/$/\n  default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96/}'  $KRB_CONF
		sed -i -e '/libdefaults/{s/$/\n  permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96/}'    $KRB_CONF
		sed -i -e '/libdefaults/{s/$/\n  allow_weak_crypto = true/}' $KRB_CONF
		echo "{Info} Kerberos will choose from AES enctypes to select one for TGT and TGS procedures"
	else
		echo "{Info} Kerberos will choose a valid enctype from default enctypes (order: AES 256 > AES 128 > DES) for TGT and TGS procedures"
	fi
	echo "$ cat $KRB_CONF"
	cat $KRB_CONF

}
krb5_client_conf $DOMAIN_NAME $ADDC_FQDN $ENCRYPT

SMB_CONF_TMP="[global]
workgroup = $DOMAIN_SHORT
client signing = yes
client use spnego = yes
kerberos method = secrets and keytab
password server = $ADDC_FQDN
realm = $DOMAIN_NAME
security = ads"

ad_net_join() {
	local domain="$1"
	local passwd="$2"

	# Configure /etc/samba/smb.conf
	echo "$SMB_CONF_TMP" > $SMB_CONF
	echo "$ cat $SMB_CONF"
	cat $SMB_CONF

	if ! KRB5_TRACE=/dev/stdout kinit -V Administrator@"$domain" <<< "$passwd"; then
		echo "AD Integration Failed, cannot get TGT principal of Administrator@"$domain" during kinit"
		return 1
	fi

	if ! net ads join -k --no-dns-updates; then
		echo "AD Integration Failed, cannot join AD Domain by 'net ads'"
		return 1
	fi
}

ad_realm_join() {
	local domain="$1"
	local passwd="$2"

	realm join --user=Administrator "$domain" <<< "$passwd"
	if [[ $? -ne 0 ]]; then
		echo "AD Integration Failed when using 'realm join'"
		return 1
	fi

	# realmd creates a smb.conf only for the duration of joining
	# Setup a permanent smb.conf post realmd join to be used in tests
	SMB_CONF=/etc/samba/realmd-smb.conf
	echo "$SMB_CONF_TMP" > $SMB_CONF
}

ad_join() {
	local domain="$1"
	local passwd="$2"

	#check whether realm command exists
	which realm >/dev/null && ad_realm_join $domain ${passwd}

	if [[ $? -ne 0 ]]; then
		ad_net_join $domain ${passwd}
	fi
}

ad_join $DOMAIN_NAME ${PASSWD}

set_spn() {
	local admin="$1"; shift
	local pass="$1"; shift
	local smb_conf="$1"; shift

	for principal; do
		if ! net -s "$smb_conf" ads keytab add $principal -U ${admin}%${pass}; then
			echo "Configure Secure NFS Client Failed, cannot add principal: $principal"
			exit 1
		fi
	done

	if ! klist -e -k -t /etc/krb5.keytab; then
		echo "Configure Secure NFS Client Failed, cannot read keytab file."
		exit 1
	fi
}
if [[ -n "${SPNs// /}" ]]; then
	set_spn Administrator ${PASSWD} $SMB_CONF  $SPNs
fi

config_idmap() {
	local domain_name=$1

	# Configure /etc/sssd/sssd.conf
	authconfig --update --enablesssd --enablesssdauth --enablemkhomedir
	# Specify Standard SSSD ad_provider Configuration File
	cat <<-EOF >$SSSD_CONF
	[nss]
	  fallback_homedir = /home/%u
	  shell_fallback = /bin/sh
	  allowed_shells = /bin/sh,/bin/rbash,/bin/bash
	  vetoed_shells = /bin/ksh

	[sssd]
	  config_file_version = 2
	  domains = example.com
	  services = nss, pam, pac

	[domain/example.com]
	  id_provider = ad
	  auth_provider = ad
	  chpass_provider = ad
	  access_provider = ad
	  cache_credentials = true
	  override_homedir = /home/%d/%u
	  default_shell = /bin/bash
	  use_fully_qualified_names = True
	EOF

	sed -r -i -e "/example.com/{s//$domain_name/g}" $SSSD_CONF
	chmod 600 $SSSD_CONF
	restorecon $SSSD_CONF
	echo "$ cat $SSSD_CONF"
	cat $SSSD_CONF

	if ! service sssd restart; then
		echo "SSSD service cannot load, please check $SSSD_CONF"
		exit 1
	fi

	# Enable nfs idmapping
	modprobe nfsd; modprobe nfs
	echo "N"> /sys/module/nfs/parameters/nfs4_disable_idmapping
	echo "N"> /sys/module/nfsd/parameters/nfs4_disable_idmapping
	service rpcidmapd restart

	for user in Administrator krbtgt; do
		if ! getent passwd $user@${domain_name}  |grep ${domain_name}; then
			echo "Configure NFSv4 IDMAP Client Failed, query user information failed for $user@${domain_name}"
			exit 1
		fi
	done

	for group in "Domain Admins" "Domain Users"; do
		if ! getent group "$group"@${domain_name} |grep ${domain_name}; then
			echo "Configure NFSv4 IDMAP Client Failed, query group information failed for Domain $group@${domain_name}"
		fi
	done
}
if [[ "$CONF_IDMAP" = "yes" ]]; then
	config_idmap $DOMAIN_NAME
fi
