#!/bin/bash

socat EXEC:"/bin/bash",pty,stderr,setsid,sane PTY,link=/dev/ttyS11,setsid,raw,echo=0 &
commy /dev/ttyS11 921600
