# Commy, a barebones serial monitor

Commy is a small utility used to connect and monitor serial, UART or COM port devices.

Commy runs on Mac, Linux and Windows. Windows support is experimental.

Does (some of) the same things as [tio](https://github.com/tio/tio), [minicom](https://en.wikipedia.org/wiki/Minicom), [screen](https://www.gnu.org/software/screen/), [miniterm.py](https://github.com/pyserial/pyserial/blob/master/serial/tools/miniterm.py), [zcom](https://github.com/ZigEmbeddedGroup/zcom), [PuTTY](https://www.putty.org/), etc.

![Mac, Windows, Linux](https://github.com/ringtailsoftware/commy/actions/workflows/build.yml/badge.svg)

![](demo.gif)

# Build from source

    zig build

    zig-out/bin/commy -h

# Typical use

List available serial ports

    commy -l

    /dev/cu.usbmodem1124101
    /dev/cu.usbmodem1124203

Connect to a port

    commy /dev/cu.usbmodem1124203 115200

Commy will try to find available ports which match so connecting to `/dev/ttyUSB0` can be written as:

    commy USB0 115200

The status bar at the top shows keyboard shortcuts. Press `ctrl-a` then `q`, `\` or `x` to quit.

Log data received from a device. Only received data will be logged, unless local echo is enabled.

    commy /dev/cu.usbmodem1124203 115200 -o log.txt

Enable local echo of sent data, used for devices which do not echo back characters they receive.

    commy /dev/cu.usbmodem1124203 115200 -e

# Why use Commy?

It tells the user how to quit.

# Help text

    Usage: commy [ARGS] [OPTIONS]

    Args:
        port                                          serial port file
        speed                                         baudrate

    Options:
        -l, --list                                    List available serial ports
        -e, --echo                                    Enable local echo
        -o, --output=<output>                         Log to file
        -p, --parity=<parity>                         Parity
                                                        values: { none, even, odd, mark, space }
        -w, --wordsize=<wordsize>                     wordsize
                                                        values: { five, six, seven, eight }
        -s, --stop=<stop>                             stop
                                                        values: { one, two }
        -f, --flow=<flow>                             flow
                                                        values: { none, software, hardware }
        -h, --help                                    Print this help and exit

# Testing

If no serial device is available, commy can connect to a Linux serial terminal inside docker. From here, any standard linux terminal software can be used.

    cd linux-test
    ./lincommy.sh

This will build commy, then build a docker container and start it. Inside the container `socat` will create a virtual serial port and bind it to `bash`. commy will then connect to the virtual serial port. Quitting commy will close down the docker container.

