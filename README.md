

## Prerequisite

```
dtparam=spi=on

dtoverlay=dwc2,dr_mode=peripheral

cma=96M
dtoverlay=tc358743
dtoverlay=tc358743-audio
```

```
$ sudo modproble libcomposite
$ sudo nano /boot/firmware/cmdline.txt
# Add to the end of the single line: modules-load=dwc2,libcomposite
```