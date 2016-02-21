#!/bin/busybox sh
#
# Copyright 2016 Console, Inc. Use under GPLv2.
#
# By Chih-Wei Huang <cwhuang@linux.org.tw>
# and Thorsten Glaser <tg@mirbsd.org>
#
# Last updated 2015/10/23
#
# License: GNU Public License
# We explicitely grant the right to use the scripts
# with Android-x86 project.
#

PATH=/sbin:/bin:/system/bin:/system/xbin; export PATH

# configure debugging output
if [ -n "$DEBUG" ]; then
	LOG=/tmp/log
	set -x
else
	LOG=/dev/null
	test -e "$LOG" || busybox mknod $LOG c 1 3
fi
exec 2>> $LOG

# early boot
if test x"$HAS_CTTY" != x"Yes"; then
	# initialise /proc and /sys
	busybox mount -t proc proc /proc
	busybox mount -t sysfs sys /sys
	# let busybox install all applets as symlinks
	busybox --install -s
	# spawn shells on tty 2 and 3 if debug or installer
	if test -n "$DEBUG" || test -n "$INSTALL"; then
		# ensure they can open a controlling tty
		mknod /dev/tty c 5 0
		# create device nodes then spawn on them
		mknod /dev/tty2 c 4 2 && openvt
		mknod /dev/tty3 c 4 3 && openvt
	fi
	if test -z "$DEBUG" || test -n "$INSTALL"; then
		echo 0 0 0 0 > /proc/sys/kernel/printk
	fi
	# initialise /dev (first time)
	mkdir -p /dev/block
	echo /sbin/mdev > /proc/sys/kernel/hotplug
	mdev -s
	# re-run this script with a controlling tty
	exec env HAS_CTTY=Yes setsid cttyhack /bin/sh "$0" "$@"
fi

# now running under a controlling tty; debug output from stderr into log file
# boot up Android

error()
{
	echo $*
	return 1
}

try_mount()
{
	RW=$1; shift
	if [ "${ROOT#*:/}" != "$ROOT" ]; then
		# for NFS roots, use nolock to avoid dependency to portmapper
		RW="nolock,$RW"
	fi
	# FIXME: any way to mount ntfs gracefully?
	mount -o $RW $@ || mount.ntfs-3g -o rw,force $@
}

check_root()
{
	if [ "`dirname $1`" = "/dev" ]; then
		[ -e $1 ] || return 1
		blk=`basename $1`
		[ ! -e /dev/block/$blk ] && ln $1 /dev/block
		dev=/dev/block/$blk
	else
		dev=$1
	fi
	try_mount ro $dev /mnt || return 1
	if [ -n "$iso" -a -e /mnt/$iso ]; then
		mount --move /mnt /iso
		mkdir /mnt/iso
		mount -o loop /iso/$iso /mnt/iso
		SRC=iso
	elif [ ! -e /mnt/$SRC/ramdisk.img ]; then
		return 1
	fi
	zcat /mnt/$SRC/ramdisk.img | cpio -id > /dev/null
	if [ -e /mnt/$SRC/system.sfs ]; then
		mount -o loop /mnt/$SRC/system.sfs /sfs
		mount -o loop /sfs/system.img system
	elif [ -e /mnt/$SRC/system.img ]; then
		remount_rw
		mount -o loop /mnt/$SRC/system.img system
	elif [ -d /mnt/$SRC/system ]; then
		remount_rw
		mount --bind /mnt/$SRC/system system
	else
		rm -rf *
		return 1
	fi
	mkdir mnt
	echo " found at $1"
	rm /sbin/mke2fs
	hash -r
}

remount_rw()
{
	# "foo" as mount source is given to workaround a Busybox bug with NFS
	# - as it's ignored anyways it shouldn't harm for other filesystems.
	mount -o remount,rw foo /mnt
}

debug_shell()
{
	if [ -x system/bin/sh ]; then
		echo Running MirBSD Korn Shell...
		USER="($1)" system/bin/sh -l 2>&1
	else
		echo Running busybox ash...
		sh 2>&1
	fi
}

echo -n Detecting Console OS...

[ -z "$SRC" -a -n "$BOOT_IMAGE" ] && SRC=`dirname $BOOT_IMAGE`

for c in `cat /proc/cmdline`; do
	case $c in
		iso-scan/filename=*)
			eval `echo $c | cut -b1-3,18-`
			;;
		*)
			;;
	esac
done

mount -t tmpfs tmpfs /android
cd /android
while :; do
	for device in ${ROOT:-/dev/[hmsv][dmr][0-9a-z]*}; do
		check_root $device && break 2
		mountpoint -q /mnt && umount /mnt
	done
	sleep 1
	echo -n .
done

ln -s mnt/$SRC /src
ln -s android/system /
ln -s ../system/lib/firmware ../system/lib/modules /lib

if [ -n "$INSTALL" ]; then
	zcat /src/install.img | ( cd /; cpio -iud > /dev/null )
fi

if [ -x system/bin/ln -a \( -n "$DEBUG" -o -n "$BUSYBOX" \) ]; then
	mv /bin /lib .
	sed -i 's|\( PATH.*\)|\1:/bin|' init.environ.rc
	rm /sbin/modprobe
	busybox mv /sbin/* sbin
	rmdir /sbin
	ln -s android/bin android/lib android/sbin /
	hash -r
fi

# ensure keyboard driver is loaded
[ -n "$INSTALL" -o -n "$DEBUG" ] && busybox modprobe atkbd

if [ 0$DEBUG -gt 0 ]; then
	echo -e "\nType 'exit' to continue booting...\n"
	debug_shell debug-found
fi

# load scripts
for s in `ls /scripts/* /src/scripts/*`; do
	test -e "$s" && source $s
done

# A target should provide its detect_hardware function.
# On success, return 0 with the following values set.
# return 1 if it wants to use auto_detect
[ "$AUTO" != "1" ] && detect_hardware && FOUND=1

[ -n "$INSTALL" ] && do_install

load_modules
mount_data
mount_sdcard
setup_tslib
setup_dpi
post_detect

if [ 0$DEBUG -gt 1 ]; then
	echo -e "\nUse Alt-F1/F2/F3 to switch between virtual consoles"
	echo -e "Type 'exit' to enter Android...\n"

	debug_shell debug-late
fi

[ -n "$DEBUG" ] && SWITCH=${SWITCH:-chroot}

# We must disable mdev before switching to Android
# since it conflicts with Android's init
echo > /proc/sys/kernel/hotplug

exec ${SWITCH:-switch_root} /android /init

# avoid kernel panic
while :; do
	echo
	echo '	Android-x86 console shell. Use only in emergencies.'
	echo
	debug_shell fatal-err
done
