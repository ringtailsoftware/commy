#!/bin/bash
(cd ../ && zig build -Dtarget=x86_64-linux) && cp ../zig-out/bin/commy . && \
docker build -t lincommy . && \
docker run -ti --rm -v `pwd`:/data lincommy /init.sh

