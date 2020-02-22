mkflashimage
============

```
./mkflashimage.sh [-h] [-r] <[-l <layout file>]|[-m >/proc/mtd style layout file>]|<mtd cmdline specification>> <outfile>

./mkflashimage.sh is a tool to create flash images from multiple files based on a Linux mtdparts specifications.
It can also perform the reverse operation, dissecting an image into its partitions.

Arguments:
  -h: Show this help
  -l <layout file>: Load flash layout from flashrom-style layout file <layout file>
  -m <mtd layout file>: Load flash layout from file [mtd layout file]
  -r: Reverse operation, deconstruct <outfile> into partitions from mtd spec

Omit <mtd cmdline specification> when specifying -l or -m

Examples:
  ./mkflashimage.sh mtdparts=spi1.0:896K(u-boot),128K(u-boot-env),6144K(kernel),10240K(usrimg1@main),10240K(usrimg2),4096K(usrappfs),1024K(para) flash32m.bin
  ./mkflashimage.sh nand0:1M(u-boot),128K(u-boot-env),8M(kernel),54M(rootfs),896k(cal) flash.img
  ./mkflashimage.sh 16k(FlashReader)ro,512k(U-Boot),32k(Env),32k(bbt),9M(Linux),50M(ROMFS),4080k@0x3c00000(WinCE)ro,16k(info)ro pnx8950.img
```
