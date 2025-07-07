#!/usr/bin/env bash

# This script creates FAT32 image from 7zip archive or directory content.
# Image name consists of archive/directory name with ".img" suffix.
# It requires sudo permissions.
#
# Copyright © 2025 Michal Morawiec <mmorawiec at gmail dot com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#
# The script was prepared to create image that can be used with
# USB Mass Storage Gadget (MSG) kernel module on RPi 4B device (or similar).
# This allows the device to act as a USB drive using its USB-C port.
#
# To load g_mass_storage module with the image execute:
#   image_path=<PATH_TO_FAT32_IMAGE>
#   sudo modprobe g_mass_storage file=${image_path} removable=1 ro=0 stall=0
# In case module complains about missing serial number execute:
#   image_path=<PATH_TO_FAT32_IMAGE>
#   image_serial_no=$(md5sum $image_path | cut -d' ' -f1 | cut -c1-20)
#   # image_serial_no=$(openssl rand -hex 10)
#   # or manually assign random 20 hex char value
#   sudo modprobe g_mass_storage file=${image_path} removable=1 ro=0 stall=0 iSerialNumber="${image_serial_no}"
# For a full list of MSG module parameters see documentation:
# https://www.kernel.org/doc/Documentation/usb/mass-storage.txt
#
# To unload g_mass_storage module execute:
#   sudo modprobe -r g_mass_storage
#
# This work is based on the following:
# - https://vanheusden.com/electronics/virtual-usb/
# - https://rgsilva.com/blog/smartifying-my-hi-fi-system/
#
# As noted above this script requires sudo permissions, but there is
# a solution which works without it, but needs more disk space:
# https://github.com/Othernet-Project/dir2fat32/blob/master/dir2fat32.sh


usage()
{
    cat << EOF
Usage: $0 [-h] [-a INPUT_7ZIP_ARCHIVE] [-d INPUT_DIRECTORY] -o OUTPUT_DIRECTORY

This script creates FAT32 image from 7zip archive or directory content.
Image name consists of archive/directory name with ".img" suffix.
It requires sudo permissons.

Options:
  -h    Show this help message and exit.
  -a    Specify input 7zip archive with content for image.
  -d    Specify input directory with content for image.
  -o    Specify output directory for image.

Examples:
  $0 -a image_content.7z -o .
  $0 -d ./image_content_dir -o \$HOME
EOF
}


# Init variables for cmdline params
input_type=""
input_path=""
output_path=""

# Reset in case getopts has been used previously in the shell
OPTIND=1
while getopts "h?a:d:o:" opt; do
    case "$opt" in
        h|\?)
            usage
            exit 0
            ;;
        a)
            [[ -z "$input_type" ]] || { echo "More than one input option specified!"; exit 1; }
            input_type="archive"
            input_path=$OPTARG
            ;;
        d)
            [[ -z "$input_type" ]] || { echo "More than one input option specified!"; exit 1; }
            input_type="dir"
            input_path=$OPTARG
            ;;
        o)
            output_path=$OPTARG
            ;;
    esac
done


# Verify input data
case "$input_type" in
    "archive")
        [[ -f "$input_path" ]] || { echo "Input archive file is not valid!"; exit 1; }
        ;;
    "dir")
        [[ -d "$input_path" ]] || { echo "Input directory is not valid!"; exit 1; }
        ;;
    *)
        echo "Input type is not valid!"
        exit 1
        ;;
esac

# Verify output path
[[ -d "$output_path" ]] || { echo "Output directory is not valid!"; exit 1; }


# Get the input size
if [[ "$input_type" == "archive" ]]; then
    # Archive size (unpacked)
    input_size=$(7z l "$input_path" | tail -1 | tr -s ' ' | cut -d' ' -f3)
else
    # Directory size
    input_size=$(du -sb "$input_path" | cut -f1)
fi

# Path to output image file
image_name=$(basename "$input_path")
image_path="${output_path}/${image_name}.img"

# Preallocate space for image file
# +33MB is to account for the suggested minimum number of clusters for 32 bit FAT
image_size_mb=$(( input_size / (1024*1024) + 33 ))
fallocate -l "${image_size_mb}M" "$image_path"

# Create a new disklabel (partition table)
parted "$image_path" mklabel msdos
# Create a new partition
part_offset_sectors=2048
# Get sector size fdisk -lu, blockdev --getss, blockdev --getpbsz ?
sector_size=512
part_offset_bytes=$(( part_offset_sectors * sector_size ))
part_offset_mb=$(( part_offset_bytes / (1024*1024) ))
parted "$image_path" mkpart primary fat32 ${part_offset_mb}M 100%
#parted --align minimal "$image_path" mkpart primary fat32 0% 100%
# Create filesystem at sector offset
mkfs.fat -v -F32 -S "$sector_size" --offset "$part_offset_sectors" "$image_path"
# AI: This would create a filesystem directly on the image file without a partition table, which might not be what's desired for a "disk image".
#mkfs.fat -v -F32 "$image_path"

# Get free loop device name
image_loop_dev="$(losetup -f)"
# Create loop device from image at sector*size offset
sudo losetup -o "$part_offset_bytes" "$image_loop_dev" "$image_path"
#sudo losetup "$image_loop_dev" "$image_path"

# Mount image loop device
image_mount_dir=$(mktemp -d --tmpdir usb_image.XXXXX)
sudo mount "$image_loop_dev" "$image_mount_dir"

# Update the mounted image
if [[ "$input_type" == "archive" ]]; then
    sudo 7z x -o"${image_mount_dir}" "$input_path"
else
    sudo cp -r "${input_path}"/* "$image_mount_dir"
fi

# Unmount image loop device
sudo umount "$image_loop_dev"
rm -fr "$image_mount_dir"

# Detach loop device from image
sudo losetup -d "$image_loop_dev"
