# Arch
This repository contains my scripts for configuring Arch, as well as below guide,
which describes the installation procedure.

It is less in-depth than [Installation guide](https://wiki.archlinux.org/index.php/Installation_guide),
and does many things differently in order to fit my current preferences.

## Reference
This guide is a compilation of those articles/ gists:
- [https://gist.github.com/burningTyger/cb6e61afdeb527f4b87e57774ac40f16](https://gist.github.com/burningTyger/cb6e61afdeb527f4b87e57774ac40f16)
- [https://wiki.archlinux.org/index.php/User:Altercation/Bullet_Proof_Arch_Install#Bootloader](https://wiki.archlinux.org/index.php/User:Altercation/Bullet_Proof_Arch_Install#Bootloader)
- [https://austinmorlan.com/posts/arch_linux_install/](https://austinmorlan.com/posts/arch_linux_install/)
- [https://gist.github.com/heppu/6e58b7a174803bc4c43da99642b6094b](https://gist.github.com/heppu/6e58b7a174803bc4c43da99642b6094b)
- [https://flypenguin.de/2018/01/20/arch-full-disk-encryption-btrfs-on-efi-systems/](https://flypenguin.de/2018/01/20/arch-full-disk-encryption-btrfs-on-efi-systems/)

As well as
- [The](https://wiki.archlinux.org/index.php/Dm-crypt/System_configuration#Using_encrypt_hook)
[Almighty](https://wiki.archlinux.org/index.php/Systemd-boot)
[Arch](https://wiki.archlinux.org/index.php/Install_from_SSH)
[Wiki](https://wiki.archlinux.org/index.php/Linux_console/Keyboard_configuration)

# Arch installation procedure
Below steps were tested only on `archlinux-2019.02.01-x86_64` version of installation media.
## From archiso
#### Boot live USB in UEFI mode (verify that `/sys/firmware/efi/efivars` directory is non-empty)
#### [optional] To enable WIFI `wifi-menu` utility can be used

#### [optional] To complete the instalation via `SSH` set `root` password and start `SSH` server
``` sh
passwd
systemctl start sshd
```

#### [optional] Connect via `SSH` without adding `archiso` to `known hosts`
``` sh
ssh -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null root@LIVE_USB
```

#### Set environment variable with value being the drive (f.e. `/dev/sda`)
``` jinja
DRIVE=/dev/{{ drive }}
```

#### Wipe existing `MBR` or `GPT`
``` sh
sgdisk --zap-all $DRIVE
```

#### Create `EFI`, `cryptswap` and `cryptsystem` partitions
``` sh
sgdisk --clear \
       --new=1:0:+550MiB --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+8GiB   --typecode=2:8200 --change-name=2:cryptswap \
       --new=3:0:0       --typecode=2:8200 --change-name=3:cryptsystem \
         $DRIVE
```

#### Format `EFI` partition to `FAT32` filesystem
``` sh
mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
```

#### Create encrypted system partition
``` sh
cryptsetup luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 /dev/disk/by-partlabel/cryptsystem
```

#### Open the partition and map it `system` virtual block device
``` sh
cryptsetup open /dev/disk/by-partlabel/cryptsystem system
```

#### Open the swap partition with random key
``` sh
cryptsetup open --type plain --key-file /dev/urandom /dev/disk/by-partlabel/cryptswap swap
```

#### Set up swap area, specify label `swap` to allow `swapon` by label
``` sh
mkswap -L swap /dev/mapper/swap
```

#### Enable swap on `/dev/mapper/swap` by label specified in previous step
``` sh
swapon -L swap
```

#### Format the partition to `btrfs`
``` sh
mkfs.btrfs --force --label system /dev/mapper/system
```

#### Set helpful environment variables - mount arguments
``` sh
o=defaults,x-mount.mkdir
o_btrfs=$o,compress=lzo,ssd,noatime
```

#### Mount created partition
```
mount -t btrfs LABEL=system /mnt
```

#### Create `root`, `home` and `snapshots` subvolumes
``` sh
btrfs subvolume create /mnt/root
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/snapshots
```

#### Unmount `system` volume and mount created subvolumes
``` sh
umount -R /mnt
mount -t btrfs -o subvol=root,$o_btrfs LABEL=system /mnt
mount -t btrfs -o subvol=home,$o_btrfs LABEL=system /mnt/home
mount -t btrfs -o subvol=snapshots,$o_btrfs LABEL=system /mnt/.snapshots
```

#### Create and mount `boot` partition
``` sh
[[ -d /mnt/boot ]] || mkdir /mnt/boot
mount LABEL=EFI /mnt/boot;
```

#### Install `base` packages group
``` sh
pacstrap /mnt base
```

#### Generate `fstab` based on currently mounted devices (specifying `/mnt` as root)
``` sh
genfstab -L -p /mnt >> /mnt/etc/fstab
```

#### Adjust `fstab` so that swap will remount correctly
``` sh
sed -i 's#LABEL=swap#/dev/mapper/swap#' /mnt/etc/fstab
```

#### Specify method for mounting swap partition in `crypttab`
``` sh
echo "swap /dev/disk/by-partlabel/cryptswap /dev/urandom swap,cipher=aes-cbc-essiv:sha256,size=256" >> /mnt/etc/crypttab
```

#### __IMPORTANT__: Copy the `UUID` of proper partition - probably the only one with `crypto_LUKS` `FSTYPE`
``` sh
lsblk -f
```

#### Boot into (similar to `arch-chroot` but
systemd-nspawn -bD /mnt

## While booted into freshly installed system

#### Generate and set locale, timezone, hostname and keymap
``` sh
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
localectl set-locale LANG=en_US.UTF-8
timedatectl set-ntp 1
timedatectl set-timezone Europe/Warsaw
hostnamectl set-hostname {{ hostname }}
echo "KEYMAP=pl" > /etc/vconsole.conf
```

#### Install `base-devel` group, `btrfs` utils and (__if Intel__) Intel microcode
``` sh
pacman -Syu base-devel btrfs-progs intel-ucode
```

#### Add `encrypt` and `btrfs` [hooks](https://wiki.archlinux.org/index.php/mkinitcpio#HOOKS)
``` sh
# in future they should be replaced with sd-* hooks (boot entry's options will have to be modified accordingly)
sed 's#^HOOKS=.*$#HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems btrfs)#' /etc/mkinitcpio.conf
```

#### Generate `initramfs` image
``` sh
mkinitcpio -p linux
```

#### Install `systemd-boot` boot loader
``` sh
bootctl --path=/boot install
```

#### Create an entry for Arch by creating file `/boot/loader/entries/arch.conf` with following contents
``` jinja
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options cryptdevice=UUID={{ copied uuid }}:system:allow-discards root=/dev/mapper/system rootflags=subvol=root rd.luks.options=discard rw
```

#### And set it as default one by editing `/boot/loader/loader.conf` to match below contents
```
default arch
```

#### Execute below commands to exit spawned container and reboot the system
``` sh
poweroff
reboot 0
```

#### ...

#### Profit
