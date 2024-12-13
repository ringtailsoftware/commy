#!/bin/bash

socat PTY,link=/dev/ttyS10 PTY,link=/dev/ttyS11 &
agetty -n -c -a root ttyS10 115200 linux &
commy /dev/ttyS11 115200
