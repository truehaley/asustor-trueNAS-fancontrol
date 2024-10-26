#!/bin/bash

# which /sys/class/hwmon symlink points to the asustor_it87 ( fan speed )
hwmon_it87="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i it87 | cut -d "\"" -f 2`
echo "fan=$hwmon_it87"

fan_pwm=$(<"$hwmon_it87/pwm1")
fan_rpm=$(<"$hwmon_it87/fan1_input")
echo "current pwm=$fan_pwm rpm=$fan_rpm"

# with the it87 module loaded fan speed is readable via /sys/class/hwmon/hwmonX - the fan speed is on pwm1
#   255 = full speed, 0 = stopped
echo "setting pwm=$1"
echo $1 >$hwmon_it87/pwm1
