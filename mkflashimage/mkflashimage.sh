#!/usr/bin/env sh

# The MIT License
#
# Copyright (c) 2020 Tobias Schramm
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

set -e

IMAGE_SUFFIXES=".bin .img"

erro() {
  ( 1>&2 echo "$@" )
}

fatal() {
  erro "FATAL: $@"
  exit 1
}

warn() {
 erro "WARNING: $@"
}

flashrom_parse_hex() {
  hexnum="${1##0[xX]}"
  printf '%d' 0x"$hexnum"
}

parse_layout() {
  mtdparts="$(while read -r line; do
    # skip empty lines
    if [[ -z "$line" ]]; then
      break
    fi
    addrrange="$(echo "$line" | cut -d' ' -f1)"
    partname="$(echo "$line" | cut -d' ' -f2)"
    addr_from=$(flashrom_parse_hex "${addrrange%%:*}")
    addr_to=$(flashrom_parse_hex "${addrrange##*:}")

    # Perform address sanity check
    if [[ $addr_from -gt $addr_to ]]; then
      fatal "Invalid layout entry '$line', start address > end address"
    fi
    size=$((addr_to - addr_from + 1))
    echo -n "${size}@${addr_from}(${partname}),"
  done < "$1")"
  echo "${mtdparts%,}"
}

parse_mtd() {
  # /proc/mtd style layouts have a oneline header
  mtdparts="$(tail -n+2 "$1" | while read -r line; do
    # skip empty lines
    if [[ -z "$line" ]]; then
      break
    fi
    size=$(flashrom_parse_hex "$(echo "$line" | cut -d' ' -f2)")
    partname="$(echo "$line" | cut -d' ' -f1 | sed 's/^"//;s/"$//')"

    echo -n "${size}(${partname%:}),"
  done)"
  echo "${mtdparts%,}"
}

usage() {
  erro "$0 [-h] [-r] <[-l <layout file>]|[-m >/proc/mtd style layout file>]|<mtd cmdline specification>> <outfile>"
  erro
  erro "$0 is a tool to create flash images from multiple files based on a Linux mtdparts specifications."
  erro "It can also perform the reverse operation, dissecting an image into its partitions."
  erro
  erro "Arguments:"
  erro "  -h: Show this help"
  erro "  -l <layout file>: Load flash layout from flashrom-style layout file <layout file>"
  erro "  -m <mtd layout file>: Load flash layout from file [mtd layout file]"
  erro "  -r: Reverse operation, deconstruct <outfile> into partitions from mtd spec"
  erro
  erro "Omit <mtd cmdline specification> when specifying -l or -m"
  erro
  erro "Examples:"
  erro "  $0 mtdparts=spi1.0:896K(u-boot),128K(u-boot-env),6144K(kernel),10240K(usrimg1@main),10240K(usrimg2),4096K(usrappfs),1024K(para) flash32m.bin"
  erro "  $0 nand0:1M(u-boot),128K(u-boot-env),8M(kernel),54M(rootfs),896k(cal) flash.img"
  erro "  $0 16k(FlashReader)ro,512k(U-Boot),32k(Env),32k(bbt),9M(Linux),50M(ROMFS),4080k@0x3c00000(WinCE)ro,16k(info)ro pnx8950.img"
  exit 1
}

unset MTDPARTS
unset REVERSE
while getopts 'l:m:rh' opt; do
  case "$opt" in
    l) MTDPARTS="$(parse_layout "$OPTARG")" ;;
    m) MTDPARTS="$(parse_mtd "$OPTARG")" ;;
    r) REVERSE=1 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# mtd partitions have not been parsed yet, get from positional arg
if [[ -z "$MTDPARTS" ]]; then
  MTDPARTS="$(echo $1 | cut -d'=' -f2 | cut -d':' -f2)"
  shift 2> /dev/null || usage
fi

OUTFILE="$1"
if [[ -z "$OUTFILE" ]] || [[ -z "$MTDPARTS" ]]; then
  usage
fi

# Emulates Linux /lib/cmdline.c memparse
memparse() {
  size="$(echo "$1" | sed 's/[^0-9a-fA-F]$//')"
  size=$(printf '%d' "$size")
  case "$1" in
    *K|*k) size=$((size * 1024)) ;;
    *M|*m) size=$((size * 1024 * 1024)) ;;
    *G|*g) size=$((size * 1024 * 1024 * 1024)) ;;
  esac
  echo $size  
}

# Parse size from mtd specification
parse_size() {
  spec="${1%%@*}"
  memparse "$spec"
}

# Parse offset from mtd specification
# Return $2 when offset not specified
parse_offset() {
  spec="${1##*@}"
  if [[ "$spec" != "$1" ]]; then
    memparse "$spec"
  else
    echo "$2"
  fi
}

# Greatest common divisor
gcd() {
  a=$1
  b=$2
  if [[ $a -eq 0 ]]; then
    echo $b
  else
    while [[ $b -ne 0 ]]; do
      if [[ $a -gt $b ]]; then
        a=$((a - b))
      else
        b=$((b - a))
      fi
    done
    echo $a
  fi
}

# Insert file into image without size check
insert_file_unchecked() {
  srcfile="$1"
  offset=$2
  size=$3
  bs=$(gcd $offset $size)

  cat "$srcfile" /dev/zero | dd of="$OUTFILE" bs=$bs seek=$((offset / bs)) count=$((size / bs)) conv=notrunc 2> /dev/null
}

# Insert file into image with size check
insert_file() {
  srcfile="$1"
  offset=$2
  size=$3
  fsize="$(wc -c < "$srcfile")"

  erro "Adding '$srcfile' at offset $2"
  if [[ "$fsize" -lt "$size" ]]; then
    warn 'Input file smaller than partition, padding with nullbytes'
  fi
  insert_file_unchecked "$srcfile" "$offset" "$size"
}

# Insert partition into image
insert_part() {
  name="$1"
  offset=$2
  size=$3

  unset found
  old_ifs="$IFS"
  IFS="$DEFAULT_IFS"
  for suffix in "" $IMAGE_SUFFIXES; do
    fname="${name}${suffix}"
    if [[ -e "$fname" ]]; then
      found=1
      insert_file "$fname" $offset $size
      break
    fi
  done
  IFS="$old_ifs"
  if [[ -z "$found" ]]; then
    warn "File for partition '$name' not found, filling with nullbytes"
    insert_file_unchecked /dev/zero $offset $size
  fi
}

# Extract partition from flash image
extract_part() {
  offset=$1
  size=$2
  dstfile="$3"
  bs=$(gcd $offset $size)

  erro "Extracting partition '$name'"
  dd if="$OUTFILE" bs=$bs skip=$((offset / bs)) count=$((size / bs)) of="$dstfile" 2> /dev/null
}

offset=0
DEFAULT_IFS="$IFS"
IFS=','
# Iterate over mtd partition definitions
for part in $MTDPARTS; do
  sizespec="$(echo "$part" | sed 's/(.*).*//')"
  name="$(echo "$part" | sed 's/^.*(\(.*\)).*/\1/' | cut -d'@' -f1)"
  size=$(parse_size "$sizespec")
  offset=$(parse_offset "$sizespec" $offset)

  # Reverse operation, extract partitions from flash image file
  if [[ -n "$REVERSE" ]]; then
    extract_part $offset $size "$name"
  else
    insert_part "$name" $offset $size
  fi

  offset=$((offset + size))
done
