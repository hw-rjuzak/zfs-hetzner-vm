# zfs-hetzner-vm

[![shellcheck](https://github.com/hw-rjuzak/zfs-hetzner-vm/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/hw-rjuzak/zfs-hetzner-vm/actions/workflows/shellcheck.yml)

Scripts to convert Debian 13 or Ubuntu 22 LTS with ZFS root on Hetzner servers (virtual and dedicated).<br/>

It will pack the current system into ram, create zfs polls and unpack the system. 

## How to use:

* Login into Hetzner cloud server console.
* Choose "rescue" menu.
* Click "enable rescue and power cycle",  add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power cycle" button.
* connect via SSH to rescue console, and run the script from this repo.


Convert the server to zfs

````bash
wget -qO- https://raw.githubusercontent.com/hw-rjuzak/zfs-hetzner-vm/master/hetzner-zfs-convert.sh | bash -
````


Answer script questions about desired ZFS ARC cache size.

To cope with network failures it's highly recommended to run the commands above inside screen console, type `man screen` for more info.
Example of screen utility usage:

````bash
export LC_ALL=en_US.UTF-8 && screen -S zfs
````
To detach from screen console, hit Ctrl-d then a
To reattach, type `screen -r zfs`

Upon successful run, the script will reboot system, and you will be able to login into it, using the same SSH key you have used within rescue console

