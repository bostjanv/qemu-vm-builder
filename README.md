# QEMU Image Maker

## Prepare rootfs (btrs raw image)
```bash
./prepare-ubuntu-rootfs-bwrap.sh ubuntu-base-26.04-base-amd64.tar.gz image.raw 8G ~/.ssh/id_rsa.pub
```

## Build kernel with all required modules built-in
```bash
./build-microvm-kernel.sh 6.18.59 ./bzImage-btrfs
```

## Boot VM
```
./boot-ubuntu-microvm.sh ./bzImage-btrfs ./image.raw
```

## ssh into VM
```bash
ssh -p 2222 alice@127.0.0.1
```

## Shutdown VM
```bash
ssh -p 2222 alice@127.0.0.1 sudo poweroff
```

## Post installation steps
- Install and enable BEES for automatic background deduplication
