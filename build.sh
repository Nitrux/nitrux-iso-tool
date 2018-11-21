#! /bin/sh 

# -- Exit on errors.

set -e


# -- Prepare the directories for the build.

BUILD_DIR=$(mktemp -d)
ISO_DIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)


# -- The name of the ISO image.

IMAGE=nitrux_release_$(printf $TRAVIS_BRANCH | sed 's/master/stable/')


# -- Function for running commands in a chroot.

run_chroot () {

	mountpoint -q $BUILD_DIR/dev/ || \
		rm -rf $BUILD_DIR/dev/*

	mount -t proc -o nosuid,noexec,nodev . $BUILD_DIR/proc
	mount -t sysfs -o nosuid,noexec,nodev,ro . $BUILD_DIR/sys
	mount -t devtmpfs -o mode=0755,nosuid . $BUILD_DIR/dev
	mount -t tmpfs -o nosuid,nodev,mode=0755 . $BUILD_DIR/run
	mount -t tmpfs -o mode=1777,strictatime,nodev,nosuid . $BUILD_DIR/tmp

	cp /etc/resolv.conf $BUILD_DIR/etc
	cp -r configs $BUILD_DIR

	if [ -f $1 -a -x $1 ]; then
		cp $1 $BUILD_DIR/
		chroot $BUILD_DIR/ /$@
		rm -r $BUILD_DIR/$1
	else
		chroot $BUILD_DIR/ $@
	fi

	for d in $BUILD_DIR/*; do
		mountpoint -q $d && \
			umount -f $d
	done

	rm -rf \
		$BUILD_DIR/etc/resolv.conf \
		$BUILD_DIR/configs

}


# -- Prepare the directory where the filesystem will be created.

wget -O base.tar.gz -q http://cdimage.ubuntu.com/ubuntu-base/releases/18.04/release/ubuntu-base-18.04.1-base-amd64.tar.gz
tar xf base.tar.gz -C $BUILD_DIR


# -- Create the filesystem.

run_chroot bootstrap.sh || true


# -- Copy the kernel and initramfs to $ISO_DIR.

cp $BUILD_DIR/vmlinuz $ISO_DIR/boot/kernel
cp $BUILD_DIR/initrd.img $ISO_DIR/boot/initramfs


# -- Clean the filesystem.

run_chroot apt -yy -qq purge --remove casper lupin-casper
run_chroot apt -yy -qq autoremove

rm -rf \
	$BUILD_DIR/tmp/* \
	$BUILD_DIR/boot \
	$BUILD_DIR/vmlinuz* \
	$BUILD_DIR/initrd.img* \
	$BUILD_DIR/var/log/* \
	$BUILD_DIR/var/lib/dbus/machine-id


# -- Compress the root filesystem.

(while :; do sleep 300; printf ".\n"; done) &

mkdir -p $ISO_DIR/casper
mksquashfs $BUILD_DIR $ISO_DIR/casper/filesystem.squashfs -comp xz -no-progress


# -- Write a short version of the commit hash that generated the image.

#du -sx --block-size=1 $ISO_DIR/ | tail -n 1 | awk '{ print $1 }' > $ISO_DIR/casper/filesystem.size
printf "${TRAVIS_COMMIT:0:7}" > $ISO_DIR/.git-commit


# -- Generate the ISO image.

wget -qO /bin/mkiso https://raw.githubusercontent.com/Nitrux/mkiso/master/mkiso
chmod +x /bin/mkiso

mkiso -d $ISO_DIR -V "NITRUX_OS" -g $CONFIG_DIR/grub.cfg -g $CONFIG_DIR/loopback.cfg -o $OUTPUT_DIR/$IMAGE


# -- Embed the update information in the image.

UPDATE_URL=http://88.198.66.58:8000/$IMAGE.zsync
printf "zsync|$UPDATE_URL" | dd of=$OUTPUT_DIR/$IMAGE bs=1 seek=33651 count=512 conv=notrunc


# -- Calculate the checksum.

sha256sum $IMAGE > $OUTPUT_DIR/$IMAGE.sha256sum


# -- Generate the zsync file.

zsyncmake $IMAGE -u ${UPDATE_URL/.zsync} -o $IMAGE.zsync


# -- Upload the ISO image.

export SSHPASS=$DEPLOY_PASS

for f in *; do
    sshpass -e scp -o stricthostkeychecking=no $f $DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PATH > /dev/null
done
