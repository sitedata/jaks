###############################################
# Begin %pre configuration script             #
###############################################
%pre --interpreter=/bin/bash --log=/dev/tty3


###############################################
# Environment variables & settings            #
###############################################

# Setup the env (setting /dev/tty3 as default IO)
chvt 3
exec < /dev/tty3 > /dev/tty3 2>/dev/tty3

# Set $PATH to something robust
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin


###############################################
# Default API arguments                       #
###############################################

# Set DEBUG = false, pauses occur at each report
DEBUG=false

# Set INSTALL = false; if not user is prompted to wipe system
# This will not prevent prompts if ROOTPW &/or LOCATION cannot be determined
INSTALL=false

# ROOTPW is empty but should be provided as command line arg to facilitate
# automation (no user interaction)
ROOTPW=

# LOCATION defaults to 'America/Denver' but can be provided at boot
LOCATION="America/Denver"

# LANG defaults to 'en_US.UTF-8' but can be provided at boot
LANG="en_US.UTF-8"

# HOSTNAME is empty but if provided & conforms to naming standard will be used
# to set LOCATION. Also, if HOSTNAME is not provided every attempt is made to
# use a DHCP provided hostname
HOSTNAME=

# IPADDR can be used to setup the network. If it is not provided the tool will
# attempt to obtain the value from anything provided by DHCP. It will take
# precedence over anything provided by DHCP as well
IPADDR=

# NETMASK like IPADDR can be used to setup the network. DHCP settings will be
# used in the event is not present.
NETMASK=

# GATEWAY can also be specified or the DHCP provided gateway will be used
GATEWAY=

# DVD is used for DVD or no network based installations
DVD=false

# Proxy server for RHN registration
PROXY=false

# Proxy username
PROXYUSER=

# Proxy password
PROXYPASS=


###############################################
# General configuration variables             #
###############################################

# Global variable for hostname
hostname=

# Global variable for location
location=

# Disk debugging log
dlog=/tmp/disks.log

# Name of %post configuration scripts
buildtools="jaks-post-config"

# Build-tools execution directory (chroot env)
buildenv=/mnt/sysimage/var/tmp/${buildtools}/


###############################################
# Disk specific variables & templates         #
###############################################

# 100GB in bytes; definitively determines vm or physical installation
gbytes=107374182400

# Physical group creation variable
pv_tmpl="part {ID} --size={SIZE} --grow --ondisk={DISK}"

# 'optappvg' volgroup variable; used when phsyical disks > 1
vg_tmpl="volgroup optappvg {ID} --pesize=4096"

# 'optlv' variable for logical volume creation
lv_tmpl="logvol /opt --fstype=ext4 --name=optlv --vgname={VOLGROUP} \
--size={SIZE}"

# '/boot/efi' partition template
efi_tmpl="part /boot/efi --size={SIZE} --fstype="efi" --ondisk={PRIMARY}"

# Grub installation template
grub_tmpl="bootloader --location={GRUB} --driveorder={DISK} --append=\"rhgb quiet crashkernel=512M audit=1\""

# Define a template for disk configurations
read -d '' disk_template <<"EOF"
# Zero the MBR
zerombr

# Clear out partitions for {DISKS}
clearpart --all --initlabel --drives={DISKS}

# Create a /boot partition on {PRIMARY} of 500MB
part /boot --size=500 --fstype="ext4" --ondisk={PRIMARY}

# If EFI is used, ensure we have a /boot/EFI partition
{EFI}

# Create an LVM partition of {SIZE}MB on {PRIMARY}
part pv.root --size={SIZE} --ondisk={PRIMARY} --grow --asprimary

# Create the root volume group
volgroup rootvg --pesize=4096 pv.root

# Create a memory partition of {SWAP}MB
logvol swap --fstype="swap" --name="swaplv" --vgname="rootvg" --size={SWAP}

# Create logical volume for the / mount point
logvol / --fstype="ext4" --name="rootlv" --vgname="rootvg" --size={ROOTLVSIZE}

# Create logical volume for the /var mount point
logvol /var --fstype="ext4" --name="varlv" --vgname="rootvg" --size={VARLVSIZE}

# Create logical volume for the /export/home mount point
logvol /export/home --fstype="ext4" --name="homelv" --vgname="rootvg" \
--size={HOMELVSIZE}

# Create logical volume for the /tmp mount point
logvol /tmp --fstype="ext4" --name="tmplv" --vgname="rootvg" --size={TMPLVSIZE}

EOF

# 'Extra' disk report
read -d '' extra_disk_report <<"EOF"
Extended:
  Logical Volume Configuration:
    |_ optapppv       {disks}
    | |_ optappvg                   {size}MB
    |___|_ optlv:     /opt          {opt_size}MB
EOF

# 'VM' disk report
vm_disk_report="    |___|_ optlv:      /opt         {opt_size}MB"

# Final disk report
read -d '' disk_report <<"EOF"
Disk configuration:

Primary:
  Physical Partitions:
    |_ {disk}1:          /boot         500MB
  Logical Volume Configuration:
    |_ rootpv         {disk}
    | |_ rootvg                     {size}MB
    |   |_ swaplv:    swap          {swap}MB
    |   |_ rootlv:    /             {root_size}MB
    |   |_ varlv:     /var          {var_size}MB
    |   |_ homelv:    /export/home  {home_size}MB
    |   |_ tmplv:     /tmp          {tmp_size}MB
EOF

# Set the -x flag for debugging if ${DEBUG} = true
if [ "${DEBUG}" == "true" ]; then
  set -x
fi


###############################################
# Function definitions - general              #
###############################################

# Pause function handle pausing if ${DEBUG} = true
function pause()
{
  local continue=
  while [ "${continue}" != "yes" ]; do
    read -p "Paused; Continue? " continue
    echo ""
  done
}

# Search array
function in_array()
{
  local args=("${@}")
  local needle="${args[0]}"
  local haystack=("${args[@]:1}")

  for i in ${haystack[@]}; do
    if [[ ${i} == ${needle} ]]; then
      return 0
    fi
  done

  return 1
}


# Function to handle API boot params
function bootparams()
{
  # Capture array of arguments
  local opts=($(cat /proc/cmdline))

  # Iterate ${opts[@]} & extract args key/values
  if [ ${#opts[@]} -gt 1 ]; then
    for opt in "${opts[@]}"; do
      i=$((i+1))
      key="$(echo "${opt}"|awk '{split($0, obj, "=");print obj[1]}')"
      value="$(echo "${opt}"|awk '{split($0, obj, "=");print obj[2]}')"
      eval ${key}=${value}
    done
  fi
}


# Confirmation of installation function
function confirminstall()
{
  # Force prompt if ${INSTALL} not present
  if [ "${INSTALL}" != "true" ]; then
    install="no"
  else
    install="yes"
  fi

  # Ensure user knows they are going to wipe out the machine
  while [ "${install}" != "yes" ]; do
    clear
    echo '********************************************************************'
    echo '*                 ____.  _____   ____  __.  _________              *'
    echo '*                |    | /  _  \ |    |/ _| /   _____/              *'
    echo '*                |    |/  /_\  \|      <   \_____  \               *'
    echo '*            /\__|    /    |    \    |  \  /        \              *'
    echo '*            \________\____|__  /____|__ \/_______  /              *'
    echo '*                             \/        \/        \/               *'
    echo '*                  Just Another Kickstart Script                   *'
    echo '*                                                                  *'
    echo '*                          W A R N I N G                           *'
    echo '*                                                                  *'
    echo '*  This process will install a completely new operating system     *'
    echo '*  while destroying all data on all non-usb & non-network storage  *'
    echo '*                                                                  *'
    echo '*         Do you wish to continue?  Type "yes" to proceed          *'
    echo '*                                                                  *'
    echo '********************************************************************'
    echo

    # Get input from user
    read -p "Proceed with install? " install

    # If 'no' proceed to shut down system
    if [ "${install}" == "no" ]; then
      echo "Shuting down ... "
      shutdown -h now
    fi
  done
}


# Configures the root user
function configureroot()
{

  # If ${ROOTPW} preset copy to ${pass}
  if [ "${ROOTPW}" != "" ]; then
    pass="${ROOTPW}"
  fi

  # Prompt for root password, hash and write it out
  while [ "${pass}" == "" ]; do
    echo "No root password specified; use ROOTPW=<pass> as boot arg to skip"
    read -sp "Enter root user password: " pass
    echo ""
  done

  # Write ${pass} to rootpw
  echo "rootpw ${pass}" > /tmp/ks-rootpw
}


# Configure the hostname (either arg or dhcp)
function configurehostname()
{
  local hname=

  # Set ${hostname}: ${args[HOSTNAME]} or value of `uname -n`
  if [ "${HOSTNAME}" == "" ]; then

    # Get the current hostname
    hname="$(uname -n)"

    # If static DHCP enabled option 12 *might* contain the appropriate hostname
    if [[ ! "${hname}" =~ localhost ]]; then
      hostname="${hname}"
    fi
  else
    # Set ${hostname} to global ${HOSTNAME}
    hostname="${HOSTNAME}"

    # Set the current OS hostname to ${hostname}
    hostname "${hostname}"
  fi
}


# Configures the proxy if required
function configureproxy()
{

  # If ${PROXY} & ${REGISTER} == true make sure we have ${PROXY}, ${PROXYUSER} & ${PROXYPASS}
  if [[ "${PROXY}" != "false" ]] && [[ "${REGISTER}" == "true" ]]; then

    # Handle ${PROXY} if missing
    if [[ "${PROXY}" == "" ]]; then
      while [ "${PROXY}" == "" ]; do
        echo "No proxy URI specified; use PROXYU=<uri> as boot arg to skip"
        read -p "Enter proxy URI: " PROXY
        echo ""
      done
    fi

    # Handle ${PROXYUSER} if missing
    if [[ "${PROXYUSER}" == "" ]]; then
      while [ "${PROXYUSER}" == "" ]; do
        echo "No proxy username specified; use PROXYUSER=<user> as boot arg to skip"
        read -p "Enter proxy username: " PROXYUSER
        echo ""
      done
    fi

    # Handle ${PROXYPASS} if missing
    if [[ "${PROXYPASS}" == "" ]]; then
      while [ "${PROXYPASS}" == "" ]; do
        echo "No proxy password specified; use PROXYPASS=<password> as boot arg to skip"
        read -sp "Enter proxy password: " PROXYPASS
        echo ""
      done
    fi
  fi
}


# Setup timezone configurations
function configuretimezone()
{
  # Write out /tmp/timezone
  echo "timezone ${LOCATION} --isUtc" > /tmp/ks-timezone
}


###############################################
# Function definitions - math                 #
###############################################

# Calculate kilobytes to bytes
function kb2b()
{
  echo $(expr ${1} \* 1024)
}


# Calculate mb2bytes to bytes
function mb2b()
{
  echo $(expr ${1} \* 1024 \* 1024)
}


# Calculate gigabytes to MB
function gb2mb()
{
  echo $(expr ${1} \* 1024)
}


# Calculate gigabytes to KB
function gb2kb()
{
  echo $(expr ${1} \* 1024 \* 1024)
}


# Calculate gigabytes to bytes
function gb2b()
{
  echo $(expr ${1} \* 1024 \* 1024 \* 1024)
}


# Calculate kilobytes to MB
function kb2mb()
{
  echo $(expr ${1} / 1024)
}


# Calculate bytes to MB
function b2mb()
{
  echo $(expr ${1} / 1024 / 1024)
}


# Return bytes based on % of total
function percent()
{
  total=${1}
  percent=${2}

  echo $((${total} / 100 * ${percent}))
}


###############################################
# Function definitions - disks                #
###############################################

# Function to handle disk template creation for dynamic disks
function configuredisks()
{
  local disk="${1}"  # comma seperated list; i.e. sda:size,sdb:size etc
  local swap="${2}"  # swap disk space (physical memory x 1)

  local optapp=0     # Is set to 1 when multiple disks are used for /opt

  # Set ${efi} to empty
  local efi=

  # Set ${partitions} to empty
  local partitions=

  # Convert ${disks} into an array (${disks[@]})
  IFS=',' read -a disks <<< "${disk}"

  # If ${#disks[@]} > 1 send to 'multipledisks()' function
  if [ ${#disks[@]} -gt 1 ]; then

     # Call multipledisks() which creates a complex entry to handle /opt
    multipledisks "${disk}"

    # Set ${optapp} = 1 to prevent duplication on primary disk
    optapp=1
  fi

  # Create string of disks to clear out partitons on
  for dsk in ${disks[@]}; do

    # Get the disk name
    prt="$(echo "${dsk}"|awk '{split($0, obj, ":");print obj[1]}')"

    # If ${partitons} is empty use ${prt}
    if [ "${partitions}" == "" ]; then
      partitions="${prt}"
    else
      partitions="${partitions},${prt}"
    fi
  done

  # Copy ${disks[0]} to ${disk}
  local disk="$(echo "${disks[0]}"|awk '{split($0, obj, ":");print obj[1]}')"

  # Copy ${disks[0]} to ${size}
  local size=$(echo "${disks[0]}"|awk '{split($0, obj, ":");print obj[2]}')

  # Make a copy of ${size} for evaluating paritition scheme
  local evalsize=${size}

  # First remove 500 (/boot) & ${swap} from ${size}
  size=$(expr ${size} - $(expr $(mb2b 500) + ${swap}))

  # If EFI boot used create a 500MB partition for /boot/efi
  if [ -d /sys/firmware/efi ]; then

    # Remove 500MB from ${size}
    size=$(expr ${size} - $(mb2b 500))

    # Re-write ${efi_tmpl} with the correct ${disk} & size
    efi=$(echo "${efi_tmpl}" |
      sed -e "s|{SIZE}|500|g" -e "s|{PRIMARY}|${disk}|g")

    # Use ${bid} to rewrite ${grub_tmpl}
    echo "${grub_tmpl}" |
      sed -e "s|{GRUB}|partition|g" \
          -e "s|{DISK}|${disk}|g" > /tmp/ks-grubinstall
  else

    # Use MBR to rewrite ${grub_tmpl} because it isn't an EFI installation
    echo "${grub_tmpl}" |
      sed -e "s|{GRUB}|mbr|g" \
          -e "s|{DISK}|${disk}|g" > /tmp/ks-grubinstall
  fi

  # Build physical system size in bytes
  pssize=$(expr $(gb2b 100) + $(gb2b 40) + $(gb2b 10) + $(gb2b 2))

  # If ${evaldisk} size > 100GB & > ${pssize}; assume physical
  if [[ ${evalsize} -gt ${gbytes} ]] && [[ ${evalsize} -ge ${pssize} ]]; then

    # 100GB / LVM
    root_size=$(gb2b 100)

    # 40GB /var LVM
    var_size=$(gb2b 40)

    # 10GB /export/home LVM
    home_size=$(gb2b 10)

    # 2GB /tmp LVM
    tmp_size=$(gb2b 2)
  fi

  # If ${evalsize} size == 100GB && < ${pssize}; assume vm
  if [[ ${evalsize} -ge ${gbytes} ]] && [[ ${evalsize} -le ${pssize} ]]; then

    # 40GB / LVM
    root_size=$(gb2b 40)

    # 20GB /var LVM
    var_size=$(gb2b 20)

    # 10GB /export/home LVM
    home_size=$(gb2b 10)

    # 2GB /tmp LVM
    tmp_size=$(gb2b 2)
  fi

  # If ${evaldisk} size < 100GB; split disk
  if [ ${evalsize} -lt ${gbytes} ]; then

    # Allocate 40% of ${size} for /root (rootlv)
    root_size=$(percent ${size} 40)

    # Allocate 20% of ${size} for /var (varlv)
    var_size=$(percent ${size} 20)

    # Allocate 10% of ${size} for /export/home (homelv)
    home_size=$(percent ${size} 10)

    # Allocate 2% of ${size} for /tmp (tmplv)
    tmp_size=$(percent ${size} 2)
  fi

  # Validate that we have some partition sizes
  if [[ -z ${root_size} ]] || [[ -z ${var_size} ]] || [[ -z ${home_size} ]] || \
      [[ -z ${tmp_size} ]]; then
    echo "Partition sizes were not determined, exiting"
    exit 1
  fi

  # Add ${root_size}, ${var_size}, ${home_size} & ${tmp_size}
  total_parts=$(expr ${root_size} + ${var_size} + ${home_size} + ${tmp_size})

  # Calculate ${opt_size} based on ${size} - ${total_parts}
  total_size=$(expr ${size} - ${total_parts})

  # Remove 2% overhead from ${opt_size}
  #opt_size=$(expr ${total_size} - $(percent ${total_size} 2))

  # Remove 75% and use as ${opt_size} because RHEL keeps changing the LVM API
  remove=$(expr ${total_size} - $(percent ${total_size} 75))
  opt_size=$(expr ${total_size} - ${remove})

  # If /opt isn't defined create it in /tmp/ks-diskconfig-extra
  if [ ${optapp} -eq 0 ]; then
    echo "$(echo "${lv_tmpl}" |
      sed -e "s|{VOLGROUP}|rootvg|g" \
          -e "s|{SIZE}|$(b2mb ${opt_size})|g")" >> /tmp/ks-diskconfig-extra

    # Also generate a report
    echo "${vm_disk_report}" |
      sed -e "s|{opt_size}|$(b2mb ${opt_size})|g" \
        > /tmp/ks-report-disks-extra
  fi

  # If ${DEBUG} is true log
  if [ "${DEBUG}" == "true" ]; then
    echo "" >> ${dlog}
    echo "COND: ${pssize}" >> ${dlog}
    echo "" >> ${dlog}
    echo "PV: pv.root ${disk} $(b2mb ${size})MB (${size} bytes)" >> ${dlog}
    echo "VG Total: $(b2mb ${size})MB (${size} bytes)" >> ${dlog}
    echo "" >> ${dlog}
    echo "LV Total: $(b2mb ${total_parts})MB (${total_parts} bytes)" >> ${dlog}
    echo "  LV root: $(b2mb ${root_size})MB (${root_size} bytes)" >> ${dlog}
    echo "  LV var: $(b2mb ${var_size})MB (${var_size} bytes)" >> ${dlog}
    echo "  LV home: $(b2mb ${home_size})MB (${home_size} bytes)" >> ${dlog}
    echo "  LV tmp: $(b2mb ${tmp_size})MB (${tmp_size} bytes)" >> ${dlog}
    if [ ${optapp} -eq 0 ]; then
      echo "  LV optapp: $(b2mb ${opt_size})MB (${opt_size} bytes)" >> ${dlog}
    fi
  fi

  # Write out /tmp/ks-diskconfig using ${disk_template}
  echo "${disk_template}" |
    sed -e "s|{DISKS}|${partitions}|g" \
        -e "s|{EFI}|${efi}|g" \
        -e "s|{SWAP}|$(b2mb ${swap})|g" \
        -e "s|{SIZE}|$(b2mb ${size})|g" \
        -e "s|{PRIMARY}|${disk}|g" \
        -e "s|{ROOTLVSIZE}|$(b2mb ${root_size})|g" \
        -e "s|{VARLVSIZE}|$(b2mb ${var_size})|g" \
        -e "s|{HOMELVSIZE}|$(b2mb ${home_size})|g" \
        -e "s|{TMPLVSIZE}|$(b2mb ${tmp_size})|g" >> /tmp/ks-diskconfig

  # Write a report of the disk configuration
  echo "${disk_report}" |
    sed -e "s|{disk}|${disk}|g" \
        -e "s|{swap}|$(b2mb ${swap})|g" \
        -e "s|{size}|$(b2mb ${size})|g" \
        -e "s|{root_size}|$(b2mb ${root_size})|g" \
        -e "s|{var_size}|$(b2mb ${var_size})|g" \
        -e "s|{home_size}|$(b2mb ${home_size})|g" \
        -e "s|{tmp_size}|$(b2mb ${tmp_size})|g" >> /tmp/ks-report-disks

}


# Function to handle extending /opt with multiple disks
function multipledisks()
{
  local disk="${1}"

  # Convert ${disks} into an array (${disks[@]})
  disks=($(echo "${disk}"|awk 'BEGIN{RS=","}{print $1}'|sort -t: -k1))

  # Make copy of ${disks[@]:1}yes
  local copy=(${disks[@]:1})

  # If ${DEBUG} is true log
  if [ "${DEBUG}" == "true" ]; then
    echo "Disk(s): ${copy[*]}" >> ${dlog}
  fi

  # Get rid of this ${primary} & ${size} are not used here

  # Get the first element as our primary volumegroup
  local primary="$(echo "${disks[0]}"|awk '{split($0, o, ":");print o[1]}')"

  # Get the size (in bytes) of our primary volumegroup
  local size=$(echo "${disks[0]}"|awk '{split($0, o, ":");print o[2]}')

  # If ${#copy[@]} > 1 then split & iterate extending the optappvg volume group
  if [ ${#copy[@]} -ge 1 ]; then

    # Set our counter to 0
    local i=0

    # Set iteration disk size to 0
    local msize=0

    # Set total volume group size to 0
    local vsize=0

    # Placeholder for the volume group list
    local vgrplst=

    # Iterate ${copy[@]} & split into disk & size
    for dsk in ${copy[@]}; do

      # Increment each iteration
      i=$((i+1))

      # Create a new physical group name
      local dname="pv.optapp.${i}"

      # Concatinate ${dname} for the volume group creation
      if [ "${vgrplst}" == "" ]; then
        vgrplst="${dname}"
      else
        vgrplst="${vgrplst} ${dname}"
      fi

      # Get the disk name from ${dsk}
      dskname="$(echo "${dsk}"|awk '{split($0, obj, ":");print obj[1]}')"

      # Get the ${msize}
      msize=$(echo "${dsk}"|awk '{split($0, obj, ":");print obj[2]}')

      # Remove 2% overhead from ${msize}
      tsize=$(expr ${msize} - $(percent ${msize} 2))

      # If ${DEBUG} is true log
      if [ "${DEBUG}" == "true" ]; then
        echo "PV: ${dname} [${dskname} $(b2mb ${msize})MB (${msize} bytes)] ${tsize}" >> ${dlog}
      fi

      # Add ${tsize} to ${vsize}
      vsize=$(expr ${tsize} + ${vsize})

      # Combine ${dskname} to ${rdn} create value of disks for disk report
      if [ "${rdn}" != "" ]; then
        rdn="${rdn}, ${dskname}"
      else
        rdn="${dskname}"
      fi

      # Make ks-diskconfig-extra with comment
      echo "" >> /tmp/ks-diskconfig-extra
      echo "# Create new physical volume on ${dskname} as ${dname}" \
        >> /tmp/ks-diskconfig-extra

      # Generate changes for ${pv_tmpl} and write to /tmp/ks-diskconfig-extra
      echo "$(echo "${pv_tmpl}" |
        sed -e "s|{ID}|${dname}|g" \
            -e "s|{SIZE}|$(b2mb ${tsize})|g" \
            -e "s|{DISK}|${dskname}|g")" >> /tmp/ks-diskconfig-extra

    done
  fi

  # Create a header for our volume group
  echo "" >> /tmp/ks-diskconfig-extra
  echo "# Create new volume group with all physical volumes" \
    >> /tmp/ks-diskconfig-extra

  # Generate changes for ${vg_tmpl} and write to /tmp/ks-diskconfig-extra
  echo "$(echo "${vg_tmpl}" |
    sed -e "s|{ID}|${vgrplst}|g")" >> /tmp/ks-diskconfig-extra

  # Create a header for our the logical volume
  echo "" >> /tmp/ks-diskconfig-extra
  echo "# Create new logical volume for optapp" \
    >> /tmp/ks-diskconfig-extra

  # Remove 75% and use as ${vsize} because RHEL keeps changing the LVM API
  remove=$(expr ${vsize} - $(percent ${vsize} 75))
  vsize=$(expr ${vsize} - ${remove})

  # Generate changes for ${lv_tmpl} and write to /tmp/ks-diskconfig-extra
  echo "$(echo "${lv_tmpl}" |
    sed -e "s|{VOLGROUP}|optappvg|g" \
        -e "s|{SIZE}|$(b2mb ${vsize})|g")" >> /tmp/ks-diskconfig-extra

  # Generate report for 'extra' disks
  echo "${extra_disk_report}" |
    sed -e "s|{size}|$(b2mb ${vsize})|g" \
        -e "s|{disks}|${rdn}|g" \
        -e "s|{opt_size}|$(b2mb ${vsize})|g" > /tmp/ks-report-disks-extra
}


###############################################
# Network configuration functions             #
###############################################

# IPv4 validation function
function valid_ip()
{
  local  ip=${1}
  local  stat=1

  # Exit if ${ip} is empty
  if [ "${ip}" == "" ]; then
    return 0
  fi

  if [[ ${ip} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=(${ip})
    IFS=$OIFS
    if [[ ${ip[0]} -le 255 ]] && [[ ${ip[1]} -le 255 ]] && \
        [[ ${ip[2]} -le 255 ]] && [[ ${ip[3]} -le 255 ]]; then
      stat=0
    fi
  fi

  echo $stat
}

# Configure the network based on argument list
function configurenetwork()
{
  # Set /tmp/ks-networking to prevent failures
  echo "" > /tmp/ks-networking

  # Use ${ip}, ${netmask} & ${gateway} if present from command line args
  # Only copy these values if ${IPADDR}, ${NETMASK} & ${GATEWAY} don't exist
  # to ensure ability to set network to something other than possible build net
  if [[ "${ip}" != "" ]] && [[ "${netmask}" != "" ]] && \
      [[ "${gateway}" != "" ]] && [[ "${IPADDR}" == "" ]] && \
      [[ "${NETMASK}" == "" ]] && [[ "${GATEWAY}" == "" ]]; then

    IPADDR=${ip}
    NETMASK=${netmask}
    GATEWAY=${gateway}
  fi

  # Is ${IPADDR}, ${NETMASK} & ${GATEWAY} present from args list?
  if [[ "${IPADDR}" != "" ]] && [[ "${NETMASK}" != "" ]] && \
      [[ "${GATEWAY}" != "" ]]; then

    # Validate IPv4 addresses for ${IPADDR}, ${NETMASK} & ${GATEWAY}
    if [[ $(valid_ip "${IPADDR}") -ne 0 ]] || \
        [[ $(valid_ip "${NETMASK}") -ne 0 ]] || \
        [[ $(valid_ip "${GATEWAY}") -ne 0 ]]; then

      # Be informative about the failure
      [[ $(valid_ip "${IPADDR}") -ne 0 ]] && echo "IPv4 (user-supplied): ${IPADDR} is invalid"
      [[ $(valid_ip "${NETMASK}") -ne 0 ]] && echo "Netmask (user-supplied): ${NETMASK} is invalid"
      [[ $(valid_ip "${GATEWAY}") -ne 0 ]] && echo "Gateway (user-supplied): ${GATEWAY} is invalid"
    fi
  else

    # Check to see if anything was applied via DHCP

    # Figure out our structure as 'ifconfig' output changed from 6.7 - 7.0
    if [ "$(ifconfig|grep inet|grep "inet addr:")" == "" ]; then
      IPADDR="$(ifconfig|grep inet|grep -v 127.0.0.1|awk '{print $2}'|head -1)"
      NETMASK="$(ifconfig|grep inet|grep -v 127.0.0.1|awk '{print $4}'|head -1)"
    else
      IPADDR="$(ifconfig|grep inet|grep -v 127.0.0.1|cut -d : -f 2|cut -d " " -f 1|head -1)"
      NETMASK="$(ifconfig|grep inet|grep -v 127.0.0.1|cut -d : -f 4|head -1)"
    fi
    GATEWAY="$(route -n|grep ^0.0.0.0|cut -b 17-32|cut -d " " -f 1|head -1)"

    # Is ${IPADDR}, ${NETMASK} & ${GATEWAY} present?
    if [[ "${IPADDR}" != "" ]] && [[ "${NETMASK}" != "" ]] && \
        [[ "${GATEWAY}" != "" ]]; then

      # Validate IPv4 addresses for ${IPADDR}, ${NETMASK} & ${GATEWAY}
      if [[ $(valid_ip "${IPADDR}") -ne 0 ]] || \
          [[ $(valid_ip "${NETMASK}") -ne 0 ]] || \
          [[ $(valid_ip "${GATEWAY}") -ne 0 ]]; then

        # Be informative about the failure
        [[ $(valid_ip "${IPADDR}") -ne 0 ]] && echo "IPv4 (dhcp): ${IPADDR} is invalid"
        [[ $(valid_ip "${NETMASK}") -ne 0 ]] && echo "Netmask (dhcp): ${NETMASK} is invalid"
        [[ $(valid_ip "${GATEWAY}") -ne 0 ]] && echo "Gateway (dhcp): ${GATEWAY} is invalid"
      fi
    fi
  fi

  # Update /tmp/ks-arguments with network information
  sed -i "s/^IPADDR.*/IPADDR ${IPADDR}/g" /tmp/ks-arguments
  sed -i "s/^NETMASK.*/NETMASK ${NETMASK}/g" /tmp/ks-arguments
  sed -i "s/^GATEWAY.*/GATEWAY ${GATEWAY}/g" /tmp/ks-arguments

  # Use supplied ${IPADDR}, ${NETMASK} & ${GATEWAY} to write network config
  if [[ "${hostname}" != "" ]] && [[ "${IPADDR}" =~ "" ]] &&
      [[ "${NETMASK}" != "" ]] && [[ "${GATEWAY}" != "" ]]; then
    echo "network --bootproto=static --hostname=${hostname} --ip=${IPADDR} \
      --netmask=${NETMASK} --gateway=${GATEWAY}" > /tmp/ks-networking
  fi

}


###############################################
# Handling boot parameters                    #
###############################################

# Set up the API defaults provided from /proc/cmdline
bootparams

# Clear the terminal
clear


###############################################
# If ${INSTALL} != true, require confirmation #
###############################################

# Make sure user knows it will wipe out the system
confirminstall

# Clear the terminal
clear


###############################################
# Configuration for the root password         #
###############################################

# Handle root password
configureroot

# Clear the terminal
clear


###############################################
# Configuration for the hostname              #
###############################################

# Configure the hostname
configurehostname

# Clear the terminal
clear


###############################################
# Configuration for location/timezone         #
###############################################

# Configure the physical location
configuretimezone

# Clear the terminal
clear


###############################################
# Configuration for the proxy                 #
###############################################

# Setup proxy
configureproxy

# Clear the terminal
clear


###############################################
# Create a simple to parse file of options    #
###############################################

# Write arguments to /tmp/ks-arguments
cat <<EOF > /tmp/ks-arguments
DEBUG ${DEBUG}
INSTALL ${INSTALL}
DVD ${DVD}
LANG ${LANG}
LOCATION ${LOCATION}
HOSTNAME ${HOSTNAME}
IPADDR ${IPADDR}
NETMASK ${NETMASK}
GATEWAY ${GATEWAY}
PROXY ${PROXY}
PROXYUSER ${PROXYUSER}
PROXYPASS ${PROXYPASS}
nfspath ${nfspath}
buildtools ${buildtools}
buildenv ${buildenv}
EOF


###############################################
# Print out a general configuration report    #
###############################################

# Generate a report of general configuration
cat <<EOF > /tmp/ks-report-general
General options:
  DEBUG:         ${DEBUG}
  INSTALL:       ${INSTALL}
  ROOTPW:        *************

Language option:
  LANGUAGE:      ${LANG}

Location option:
  LOCATION:      ${LOCATION}

EOF

# Clear the terminal
clear
cat /tmp/ks-report-general

# If ${DEBUG} is set to true; pause
if [ "${DEBUG}" == "true" ]; then
  pause
fi


###############################################
# Configuration for DVD installations         #
###############################################

# If ${DVD} set to true write out a config
if [ "${DVD}" == "true" ]; then
  echo "cdrom" > /tmp/ks-installation
else
  touch /tmp/ks-installation
fi


###############################################
# Configuration for the networking            #
###############################################

# Generate networking configuration
configurenetwork

# Clear the terminal
clear

###############################################
# Print out the network configuration report  #
###############################################

# Generate a report of general configuration
cat <<EOF > /tmp/ks-report-network
Network configuration:
  HOSTNAME:      ${hostname}
  IPADDR:        ${IPADDR}
  NETMASK:       ${NETMASK}
  GATEWAY:       ${GATEWAY}

Proxy settings:
  PROXY:         ${PROXY}
  PROXY USER:    ${PROXYUSER}
  PROXY PASS:    *************

EOF

# Print the report
cat /tmp/ks-report-network

# If ${DEBUG} is set to true; pause
if [ "${DEBUG}" == "true" ]; then
  pause
fi


###############################################
# Configuration for physical disks            #
###############################################

# Clear the TTY
clear

# Provide a status regarding disk provisioning
echo "Provisioning disk(s), please wait ... "

# Fix for errors handling primary disk on mklabel
if [ "$(mount|grep /tmp/tfs)" != "" ]; then
  umount /tmp/tfs
fi

# Determine the amount of memory on the system, used for our swap partition
swap=$(kb2b $(cat /proc/meminfo|awk '$0 ~ /^MemTotal/{print $2}'))

# If ${DEBUG} is true log
if [ "${DEBUG}" == "true" ]; then
  echo "Boot: 500MB ($(mb2b 500) bytes)" >> ${dlog}
  echo "Swap: $(b2mb ${swap})MB (${swap} bytes)" >> ${dlog}
fi

# Get a collection of physical disks
#  Filters disk partitions & converts blocks to bytes
dsks=($(cat -n /proc/partitions |
        awk '$1 > 1 && $5 ~ /^s[a-z]+$/{print $5":"$4 * 1024}'|sort -t: -k1))

# If ${DEBUG} is true log
if [ "${DEBUG}" == "true" ]; then
  echo "Disk(s): ${dsks}" >> ${dlog}
  echo "" >> ${dlog}
fi

# Make sure ${disks[@]} is > 0
if [ ! ${#dsks[@]} -gt 0 ]; then
  echo "No physical disks present! Cannot create necessary disk configuration"
  exit 1
fi

# Iterate ${disks[@]} & remove USB devices
for item in ${dsks[@]}; do

  # Extract the disk
  disk="$(echo "${item}"|awk '{split($0, o, ":");print o[1]}')"

  # Extract the disk size
  size="$(echo "${item}"|awk '{split($0, o, ":");print o[2]}')"

  # Skip ${disk} if it is a USB device
  usb="$(readlink -f /sys/class/block/${disk}/device|grep usb)"

  if [ "${usb}" == "" ]; then

    # Obtain array of logical volumes from LVM as ${lvol[@]}
    lvol=$(lvscan|awk '{print $2}'|sed -e "s|^'||" -e "s|'$||")

    # If ${#lvol[@]} -gt 0 then remove them all
    if [ ${#lvol[@]} -gt 0 ]; then
      for lv in ${lvol[@]}; do
        lvremove -f $(basename ${lv}) &>/dev/null

        # If ${DEBUG} is true log
        if [ "${DEBUG}" == "true" ]; then
          echo "LVM: Removed LV '${lv}'" >> ${dlog}
        fi
      done
    fi

    # Obtain array of volume groups from LVM as ${vvol[@]}
    vvol=$(vgscan|awk '$0 ~ /Found volume group/{print $4}'|sed -e 's/^"//' -e 's/"$//')

    # If ${#vvol[@]} -gt 0 then remove them all
    if [ ${#vvol[@]} -gt 0 ]; then
      for vg in ${vvol[@]}; do
        vgremove -f ${vg} &>/dev/null

        # If ${DEBUG} is true log
        if [ "${DEBUG}" == "true" ]; then
          echo "LVM: Removed VG '${vg}'" >> ${dlog}
        fi
      done
    fi

    # Obtain array of volume groups from LVM as ${vvol[@]}
    pvol=$(pvscan|awk '$0 ~ /PV/{print $2}')

    # If ${#pvol[@]} -gt 0 then remove them all
    if [ ${#pvol[@]} -gt 0 ]; then
      for pv in ${pvol[@]}; do
        pvremove -f ${pv} &>/dev/null

        # If ${DEBUG} is true log
        if [ "${DEBUG}" == "true" ]; then
          echo "LVM: Removed PV '${pv}'" >> ${dlog}
        fi
      done
    fi

    # Iterate each disk & remove partition tables
    part=($(fdisk -l ${disk}|awk 'BEGIN{OFS=" "}{if ($0 ~ /^\/dev/){print $1}}'|sort -r))
    if [ ${#part[@]} -gt 0 ]; then
      for prt in ${part[@]}; do
        echo -e "$(printf 'd\n%d\nw' "${prt: -1}")"|fdisk ${disk}

        # If ${DEBUG} is true log
        if [ "${DEBUG}" == "true" ]; then
          echo "PT: Removed patition '${prt}' on '${disk}'" >> ${dlog}
        fi
      done
    fi

    # Wipe the MBR of each disk to account for 'clearpart' deficiencies
    dd if=/dev/zero of=/dev/${disk} bs=1 count=512 &>/dev/null

    # If ${DEBUG} is true log
    if [ "${DEBUG}" == "true" ]; then
      echo "PT: Removed first 512 bytes on '${disk}'" >> ${dlog}
    fi

    disks+=("${disk}:${size}")

    # If ${DEBUG} is true log
    if [ "${DEBUG}" == "true" ]; then
      echo "Wiped: ${disk} $(b2mb ${size})MB (${size} bytes)" >> ${dlog}
    fi

  fi
done

# If ${#disks[@]} > 1 combine as a comma seperated list
if [ ${#disks[@]} -gt 1 ]; then
  dsk="${disks[@]}"
  disks="${dsk// /,}"
fi

# Create disk configuration files /tmp/ks-diskconfig & /tmp/ks-diskconfig-extra
configuredisks "${disks}" "${swap}"


###############################################
# Print out the disk configuration report     #
###############################################

# Make sure our disk configuration file exist
if [[ ! -f /tmp/ks-diskconfig ]] || [[ ! -f /tmp/ks-diskconfig-extra ]]; then
  echo "Disk configuration files were not created"
  exit 1
fi

# Combine disk configuration files & remove temporary
cat /tmp/ks-diskconfig-extra >> /tmp/ks-diskconfig

# Remove the combined disk configuration
rm /tmp/ks-diskconfig-extra

# Make sure our disk report files exist
if [[ ! -f /tmp/ks-report-disks ]] || \
    [[ ! -f /tmp/ks-report-disks-extra ]]; then
  echo "Disk report files were not created"
  exit 1
fi

# Combine disk report files & remove temporary
cat /tmp/ks-report-disks-extra >> /tmp/ks-report-disks
rm /tmp/ks-report-disks-extra

# Clear the terminal
clear

# Print the disk configuration report
cat /tmp/ks-report-disks
echo ""

# If ${DEBUG} is set to true; pause
if [ "${DEBUG}" == "true" ]; then
  pause
fi


%end
###############################################
# End %pre configuration script               #
###############################################


###############################################
# Begin kick start automation procedures      #
###############################################

# Disable selinux
selinux --disabled

# Setup the installation media (if any)
%include /tmp/ks-installation

# Default language
lang en_US

# Default keyboard layout
keyboard us

# Include timezone
%include /tmp/ks-timezone

# Include root password configuration
%include /tmp/ks-rootpw

#platform x86, AMD64, or Intel EM64T

# Restart system after kicked
reboot

# Use NFS or DVD for installation media
#%include /tmp/ks-nfsshare

# Include disk configuration
%include /tmp/ks-diskconfig

# Install GRUB
%include /tmp/ks-grubinstall

# Include networking configuration
%include /tmp/ks-networking

# Specify authentication hashing algorithm
# (why is 'useshadow' even an option anymore?)
auth --passalgo=sha512 --useshadow

# Disable selinux policies
selinux --disabled

# Disable firewall
firewall --disabled

# Don't install X, riddled with vulns
skipx

firstboot --disable

# Handle package installation
%packages --ignoremissing
@Base
@Core
%end
###############################################
# End kick start automation procedures      #
###############################################


###############################################
# Begin %post non-chroot configuration        #
###############################################
%post --nochroot --interpreter=/bin/bash --erroronfail --log=/dev/tty3


###############################################
# Environment variables, functions & settings #
###############################################

# Setup the env (setting /dev/tty3 as default IO)
chvt 3
exec < /dev/tty3 > /dev/tty3 2>/dev/tty3

clear

# Set $PATH to something robust
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

# Set our env variables from /tmp/ks-arguments
DEBUG="$(cat /tmp/ks-arguments|awk '$0 ~ /^DEBUG/{print $2}')"
INSTALL="$(cat /tmp/ks-arguments|awk '$0 ~ /^INSTALL/{print $2}')"
DVD="$(cat /tmp/ks-arguments|awk '$0 ~ /^DVD/{print $2}')"
HOSTNAME="$(cat /tmp/ks-arguments|awk '$0 ~ /^HOSTNAME/{print $2}')"
IPADDR="$(cat /tmp/ks-arguments|awk '$0 ~ /^IPADDR/{print $2}')"
NETMASK="$(cat /tmp/ks-arguments|awk '$0 ~ /^NETMASK/{print $2}')"
GATEWAY="$(cat /tmp/ks-arguments|awk '$0 ~ /^GATEWAY/{print $2}')"
nfspath="$(cat /tmp/ks-arguments|awk '$0 ~ /^nfspath/{print $2}')"
buildtools="$(cat /tmp/ks-arguments|awk '$0 ~ /^buildtools/{print $2}')"
buildenv="$(cat /tmp/ks-arguments|awk '$0 ~ /^buildenv/{print $2}')"


# Pause function handle pausing if ${DEBUG} = true
function pause() {
  local continue=
  while [ "${continue}" != "yes" ]; do
    read -p "Paused; continue? " continue
    echo ""
  done
}


# Mount all block inodes searching for '${buildtools}'
function devinodes()
{
  # Obtain an array of block devices as ${blockdevs[@]}
  local blockdevs=($(ls -la /dev/ | sort -k 4 |
    awk '$10 ~ /[0-9]$/ && ($4 ~ /^cdrom$/ || $4 ~ /^disk$/){print "/dev/"$10}'))

  # Error if ${#blockdevs[@]} -lt 1
  if [ ${#blockdevs[@]} -lt 1 ]; then
    return 1
  fi

  # Make our mount point if it doesn't exist
  if [ ! -d /tmp/tfs ]; then
    mkdir -p /tmp/tfs
  fi

  # Iterate ${blockdevs[@]} and mount to find the ${buildtools}
  for dev in ${blockdevs[@]}; do

    # Skip loop, rawct, dm-* & ram device inodes
    if [[ "${dev}" =~ loop ]] || [[ "${dev}" =~ ram ]] ||
        [[ "${dev}" =~ rawctl ]] || [[ "${dev}" =~ dm- ]]; then
      continue
    fi

    # Look to see if ${dev} is currently mounted & unmount if it is
    local mnt=$(mount|grep ^${dev}|grep -v /mnt/sysimage/|awk '{print $3}')
    if [ "${mnt}" != "" ]; then
      umount ${mnt}
    fi

    # Mount & search for '${buildtools}', skip if mount fails
    local bogus=$(mount ${dev} /tmp/tfs &>/dev/null)
    if [[ $? -ne 0 ]] || [[ "$(ls ${mnt_path})" == "" ]]; then
      continue
    fi

    # Check for the ${buildtools} folder
    local needle="$(find /tmp/tfs -type d -name "${buildtools}" -print -quit)"
    if [ "${needle}" != "" ]; then
      if [ -d ${needle} ]; then
        echo "${needle}"
        return 0
      fi
    fi

    # Remove the mount while discarding errors
    umount /tmp/tfs &>/dev/null
  done

  return 1
}


# Function to recursively mount & search for '${buildtools}'
function findtools()
{
  # Search for build tools already existing on any mounted filesystems
  local haystack=$(find / -type d -name ${buildtools}|head -1)

  # If it exists return 0 and echo the path
  if [[ -d ${haystack} ]] && [[ -f ${haystack}/jaks-post-config ]]; then
    echo "${haystack}" && return 0
  fi

  return 1
}


# Function to handle moving build tools in %pre
# This might be best served as a recursive function
# to ensure we get the tools copied over
function copytools()
{
  # Setup the ${buildtools} location from ${buildenv}
  local buildloc="${buildenv}/linux/"

  # Make our mount point if it doesn't exist
  if [ ! -d /tmp/tfs ]; then
    mkdir -p /tmp/tfs
  fi

  # Check locally for ${buildtools} first
  local path="$(findtools)"

  # If the return code isn't 0 or ${path} is still empty call devinodes()
  if [[ $? -ne 0 ]] || [[ "${path}" == "" ]]; then

    # Check return from devinodes()
    path=$(devinodes)
    if [[ $? -eq 1 ]] || [[ "${path}" == "" ]]; then
      echo "Could not locate '${buildtools}' on any disk inodes"
    fi
  fi

  # If it mounts try to get our build tools
  if [[ -d ${path} ]] && [[ "${path}" != "" ]]; then

    # Make ${buildloc} exists in the right location
    if [ ! -d ${buildloc} ]; then
      mkdir -p ${buildloc}
    fi

    cp -fr ${path} ${buildloc}
  else
    echo "Could not locate '${buildtools}', exiting..."
  fi

  # Unmount /tmp/tfs if it is mounted
  local mounted="$(mount|grep /tmp/tfs)"
  if [ "${mounted}" != "" ]; then
    umount /tmp/tfs
  fi

  # Remove the /tmp/tfs folder
  if [ -d /tmp/tfs ]; then
    rm -fr /tmp/tfs
  fi
}

###############################################
# Copy DNS settings to chroot env             #
###############################################

# If /etc/resolv.conf exists do work
if [ -f /etc/resolv.conf ]; then
  cp -f /etc/resolv.conf /mnt/sysimage/etc/
fi

# Clear the terminal
clear


###############################################
# Copy build tools to temporary memory fs     #
###############################################

# Find and copy tools
echo "Searching for '${buildtools}', please wait ..."
copytools

# Clear the terminal
clear


###############################################
# If ${DVD} is true copy tools from DVD       #
###############################################

# If ${DVD} set is false get NFS mounts ready
if [ "${DVD}" == "true" ]; then

  # Generate a %pre (non-chroot) configuration report
  cat <<EOF > /tmp/ks-report-post
Post installation: (pre-chroot)
  ENV:
    - Copied configurations to chroot environment
    - Copied RHEL build tools to chroot environment

EOF
fi


###############################################
# Expose /tmp/ks* files to chroot env         #
###############################################

# Copy all of our configuration files from %pre to /mnt/sysimage/tmp
cp /tmp/ks* /mnt/sysimage/tmp


###############################################
# Print %post (non-chroot) report             #
###############################################

# Clear the terminal
clear
cat /tmp/ks-report-post |
  sed -e "s|{NFSICMP}|${nfsicmp}|g" \
      -e "s|{NFSMT}|${nfsmt}|g" \
      -e "s|{LCLBUILD}|${lclbuild}|g"

# If ${DEBUG} is set to true; pause
if [ "${DEBUG}" == "true" ]; then
  pause
fi


%end
###############################################
# End %post non-chroot configuration        #
###############################################


###############################################
# Begin %post chroot configuration            #
###############################################
%post --interpreter=/bin/bash --erroronfail --log=/dev/tty3


###############################################
# Environment variables, functions & settings #
###############################################

# Setup the env (setting /dev/tty3 as default IO)
chvt 3
exec < /dev/tty3 > /dev/tty3 2>/dev/tty3

# Set $PATH to something robust
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

clear

# Pause function handle pausing if ${DEBUG} = true
function pause() {
  local continue=
  while [ "${continue}" != "yes" ]; do
    read -p "Paused; continue? " continue
    echo ""
  done
}

# Set our env variables from /tmp/ks-arguments
DEBUG="$(cat /tmp/ks-arguments|awk '$0 ~ /^DEBUG/{print $2}')"
INSTALL="$(cat /tmp/ks-arguments|awk '$0 ~ /^INSTALL/{print $2}')"
HOSTNAME="$(cat /tmp/ks-arguments|awk '$0 ~ /^HOSTNAME/{print $2}')"
IPADDR="$(cat /tmp/ks-arguments|awk '$0 ~ /^IPADDR/{print $2}')"
NETMASK="$(cat /tmp/ks-arguments|awk '$0 ~ /^NETMASK/{print $2}')"
GATEWAY="$(cat /tmp/ks-arguments|awk '$0 ~ /^GATEWAY/{print $2}')"
PROXY="$(cat /tmp/ks-arguments|awk '$0 ~ /^PROXY/{print $2}')"
PROXYUSER="$(cat /tmp/ks-arguments|awk '$0 ~ /^PROXYUSER/{print $2}')"
PROXYPASS="$(cat /tmp/ks-arguments|awk '$0 ~ /^PROXYPASS/{print $2}')"
buildtools="$(cat /tmp/ks-arguments|awk '$0 ~ /^buildtools/{print $2}')"
buildenv="$(cat /tmp/ks-arguments|awk '$0 ~ /^buildenv/{print $2}')"


# Strip off /mnt/sysimage from ${buildenv}
buildenv="$(echo "${buildenv}"|sed -e "s|/mnt/sysimage||g")"

# Define a location for the RHEL build tool
build_tools="${buildenv}/linux/${buildtools}"


###############################################
# Validate ${buildtools} location (NFS mount) #
###############################################

# Make sure the NFS mount provided the directory
if [ ! -d "${build_tools}" ]; then
  echo "Unable to open ${build_tools}"
  exit 1
fi


###############################################
# Validate ${buildtools} exist (actual file)    #
###############################################

# Does our build tool exist?
if [ ! -f "${build_tools}/jaks-post-config" ]; then
  echo "RHEL build tool doesn't seem to exist @ ${build_tools}/jaks-post-config"
  exit 1
fi


###############################################
# Create build audit folder structure         #
###############################################

# Record a timestamped hostname string for build logs
folder=/root/${HOSTNAME:=localhost}-$(date +%Y%m%d-%H%M)

# Create a folder structure for operational logging
if [ ! -d "${folder}" ]; then
  mkdir -p ${folder}/
  mkdir -p ${folder}/kickstart
  mkdir -p ${folder}/pre
  mkdir -p ${folder}/build
  mkdir -p ${folder}/post
fi

# Go to ${build_tools}
cd ${build_tools}

echo "Please wait; auto-configuring system according to build standards"


###############################################
# Run ${buildtools} to validate current env.    #
###############################################

# Run ${build_tools} to validate current configuration with logging
./jaks-post-config -vc \
  > ${folder}/pre/${HOSTNAME}-$(date +%Y%m%d-%H%M).log 2>/dev/null


###############################################
# Configure according to RHEL build standard  #
###############################################

# Run ${build_tools} to make changes according to RHEL build guide standards
./jaks-post-config -va kickstart \
  > ${folder}/build/${HOSTNAME}-$(date +%Y%m%d-%H%M).log 2>/dev/null


###############################################
# Check for config-network tool               #
###############################################

# Run the $(dirname ${build_tools})/scripts/config-network tool by itself
# because the argument requirements differ from all the other tools

# Exit if config-network tool doesn't exist
if [ ! -f ${build_tools}/scripts/config-network ]; then
  echo "${build_tools}/scripts/config-network missing"
  exit 1
fi

# Change into scripts/ subfolder if scripts/config-network exists
cd ${build_tools}/scripts/

# Make sure our configuration data exists
if [ ! -f /tmp/ks-networking ]; then
  echo "/tmp/ks-networking file is missing, exiting"
  exit 1
fi


###############################################
# Configure network (802.1 or single) adapter #
###############################################

# Run ./config-network with network params to auto-configure bonded interfaces
# for physical servers & non-bonded interfaces for virtual machine guests
./config-network -va kickstart -n "${IPADDR}" -s "${NETMASK}" -g "${GATEWAY}" \
  > ${folder}/build/${HOSTNAME}-$(date +%Y%m%d-%H%M)-config-network.log 2>/dev/null


###############################################
# Run ${buildtools} to validate build           #
###############################################

# Change into into parent folder and validate
cd ../

# Run ${build_tools} to validate changes
./jaks-post-config -vc \
  > ${folder}/post/${HOSTNAME}-$(date +%Y%m%d-%H%M).log 2>/dev/null


###############################################
# Examine post build log for errors           #
###############################################

# log file name
log_file="${folder}/build/${HOSTNAME}-*.log"

# Get total number of tools configured to run
total=$(awk '$0 ~ /^\[/{print}' jaks-post-config|wc -l)

# Get an array of configuration scripts that were run
tools=($(awk '$0 ~ /^Executing:/{print $2}' ${log_file}))

# Provide the total number of scripts run
total_tools=${#tools[@]}

# Get an array of configuration scripts that failed
failed_tools=($(awk '{if (match($0, /.*An error.*\.(.*);.*/, obj)){print "."substr(obj[1], 1, length(obj[1])-1)}}' ${log_file}))

# Provide the total number of failed scripts run
total_failed_tools=${#failed_tools[@]}

# Get an array of configuration scripts that succeeded
successful_tools=($(awk '{if (match($0, /.*\.(.*)'\''.*successfully.*/, obj)){print "."obj[1]}}' ${log_file}))

# Provide the total number of failed scripts run
total_successful_tools=${#successful_tools[@]}


###############################################
# Re-run failed jobs individually             #
###############################################

# Should this be implemented? Or just force review of the logs?


###############################################
# Generate a %post (chroot) report            #
###############################################

# Generate a %post (chroot) configuration report
cat <<EOF > /tmp/ks-report-post-chroot
Post installation: (chroot)
  ENV:
    - Validation of build tool existence
    - Creation of reporting structure for build process
  BUILD:
    - Logs for each stage of configuration created
    - Statistical information for build:
      - Total tools run:         ${total_tools}
      - Total successful tools:  ${total_successful_tools}
      - Total failed tools:      ${total_failed_tools}
  BACKUP:
    - Backup of kickstart configurations:
      - Location & timezone configuration
      - Default root user configuration
      - Physical disk configuration
    - Backup of build logs:
      - Pre build configuration validation
      - Build configuration results
      - Post build configuration validation
    - Secured reports & configurations @ /root/${HOSTNAME}-$(date +%Y%m%d)

EOF


###############################################
# Create backup of build configuration files  #
###############################################

# Make a backup of /tmp/ks* to ${folder}/kickstart
rm /tmp/ks-script-*
cp /tmp/ks* ${folder}/kickstart

# Organize the files
mkdir ${folder}/kickstart/configs

# Create a timestamped filename
filename=${folder}/${HOSTNAME}-$(date +%Y%m%d).log

# Combine the reports
cat ${folder}/kickstart/ks-report-general > ${filename}
cat ${folder}/kickstart/ks-report-network >> ${filename}
cat ${folder}/kickstart/ks-report-disks >> ${filename}
cat ${folder}/kickstart/ks-report-post >> ${filename}
cat ${folder}/kickstart/ks-report-post-chroot >> ${filename}

# Remove the old reports
rm ${folder}/kickstart/ks-report*

# Move the configuration files used
mv ${folder}/kickstart/ks-* ${folder}/kickstart/configs

# Wipe out the ks-arguments file to clean up any provided credentials
rm ${folder}/kickstart/configs/ks-arguments

# Move the ks.cfg to the current hostname.ks
mv ${folder}/kickstart/ks.cfg ${folder}/kickstart/${HOSTNAME}.ks

# Remove everything else
rm ${folder}/ks-*

# Move build logs into their own folder
mkdir -p ${folder}/build-logs
mv -f ${folder}/pre ${folder}/build-logs
mv -f ${folder}/build ${folder}/build-logs
mv -f ${folder}/post ${folder}/build-logs


###############################################
# Setup appropriate permissions on backup     #
###############################################

# Set some permissions to account for root pw
chown -R root:root ${folder}
chmod -R 600 ${folder}


###############################################
# Print %post (non-chroot) report             #
###############################################

# Clear the terminal
clear
cat /tmp/ks-report-post-chroot

# If ${DEBUG} is set to true; pause
if [ "${DEBUG}" == "true" ]; then
  pause
fi


%end
###############################################
# End %post chroot configuration              #
###############################################

#fin
