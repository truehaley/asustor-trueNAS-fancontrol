#!/bin/bash

# Asustor Flashstor6 and Flashstor12 Pro fan control script for TrueNAS-SCALE 22
#
# Standing on the shoulders of giants: adapted from John Davis' original script at
#     https://gist.github.com/johndavisnz/06a5e1aabaf878add0ad95669b3a0b3d
#
# Updated version:
# Dynamically deal with any number of NVMe drives installed in the flashstor 6 or 12
# Removes reliance on installing packages (hddtemp, smartmontools, libraries etc) that are
#    not part of the TrueNAS standard install - avoids breaking the TrueNAS appliance
# Uses mafredri's Asustor_platform_driver (it87 branch) for the Linux kernel platform driver
#    which skips fan pwm sanity checks (note: LED control does not work with the flashstors)
#
# v1.0 05-08-2023 ( initial test version )
# v1.1 18-09-2023 ( updated curves and threshold variables )
# v1.2 24-09-2023 ( first publically available version)

# depends on:
#
# custom asustor-it87 kmod to read/set fan speeds:
#    Needs to be compiled from source - see https://github.com/mafredri/asustor-platform-driver/blob/it87/README.md
#    as the debian/TrueNAS-supplied it87 doesn't support the IT8625E used in the asustor
#    IMPORTANT: must use the it87 branch


# uses sqr(temp above threshold/2)+base_pwm for cpu/sys response curve
# uses sqr(temp above threshold/1.8)+base_pwm for NVME response curve
#
# this gives a slow initial ramp up and a rapid final ramp up across the desired temp range
#  sys range 50-75 celsius
#  NVME temp range 35-70 (1.8 will set the fan to max rpm at a temp of 60)

# Add log output to syslog
exec 1> >(logger -s -t $(basename $0)) 2>&1


# debug output level:
#   0 = disabled
#   1 = minimal, fan changes only
#   2 = verbose, all temp details
#   3 = extremely verbose
debugLvl=2

function debug() {
    declare -ri outputLvl=$1
    declare -r message=$2
    if [ $debugLvl -ge $outputLvl ]; then
        echo "$message"
    fi
}

# global variables to tune behaviour

# enable email fan change alets
mailalerts=0

# address we send email alerts to
mail_address=admin@locahost
# hostname we use to identify ourselves in email alerts
mail_hostname=truenas.local
debug 2 "STARTUP: mail_address=$mail_address mail_hostname=$mail_hostname"

# how often we check temps / set speed ( in seconds )
frequency=10

# ratio of how often we update system and nvme sensors vs hdd sensors
# sampling the sys and nvme sensors is lightweight, wheras querying the hdd sensors via SMART disrupts disk i/o - and hdd temp doesn't change that fast
ratio_sys_to_hdd=12

# the hdd temperature above which we start to increase fan speed
nvme_threshold=35
hdd_threshold=38

# the system temperatures above which we start to increase fan speed
sys_threshold=50

# minimum pwm value we ever want to set the fan to ( 70 ~= 1000 rpm on AS5404T )
min_pwm=70

# How much of a temp change do we look for before altering fan speeds so we limit fan hunting
nvme_delta_threshold=2
hdd_delta_threshold=2
sys_delta_threshold=4


#### determine the /sys/class/hwmon mappings ####


# which /sys/class/hwmon symlink points to the asustor_it87 ( fan speed )
hwmon_it87="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i it87 | cut -d "\"" -f 2`
debug 2 "STARTUP: hwmon_it87=$hwmon_it87"

# which /sys/class/hwmon symlink points to the intel coretemp sensors
hwmon_coretemp="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i coretemp | cut -d "\"" -f 2`
debug 2 "STARTUP: hwmon_coretemp=$hwmon_coretemp"

# which /sys/class/hwmon symlink points to the acpi sensors ( board temperature sensor )
hwmon_acpi="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i thermal_zone0 | cut -d "\"" -f 2`
debug 2 "STARTUP: hwmon_acpi=$hwmon_acpi"


# Use an array to find which /sys/class/hwmon symlinks point to the NVMe drive sensors and assign them sequential variables
#    This should find all NVMe drives regardless of the number installed, and assign them to
#    sequential variables hwmon_nvme1, hwmon_nvme2 ... hwmon_nvme(x)
debug 2 "STARTUP: NVMe hardware monitoring devices:"
declare -A all_hwmon_nvmes=()
i=1
while read -r path; do
  all_hwmon_nvmes["nvme$i"]="/sys/class/hwmon/$path"
  debug 2 "STARTUP nvme$i=/sys/class/hwmon/$path"
  (( i++ ))
done < <(ls -lQ /sys/class/hwmon | grep -i nvme | cut -d "\"" -f 2)

# Assign all the paths stored in the all_hwmon_nvmes array to sequential hwmon_nvme variables
#for ((j=1; j<i; j++)); do
#  variable_name="hwmon_nvme$j"
#  eval "$variable_name=\"${all_hwmon_nvmes[$j]}\""
#done

# Display the NVMe hardware monitoring devices found if debug is on
#if [ $debugLvl -ge 2 ]; then
#  echo "STARTUP: NVMe hardware monitoring devices:"
#  eval "declare -p hwmon_nvme{1..$((i-1))}"
#fi


# set fan speed to desired_pwm
function set_fan_pwm() {
    declare -ri new_pwm=$1

    # with the it87 module loaded fan speed is readable via /sys/class/hwmon/hwmonX - the fan speed is on pwm1
    #   255 = full speed, 0 = stopped
    echo $new_pwm >$hwmon_it87/pwm1
}


# query fan speed and set the global fan_rpm
function get_fan_rpm() {
    fan_rpm=$(<"$hwmon_it87/fan1_input")
    debug 2 "GET_FAN_RPM:   $fan_rpm"
}


# query all NVMe drive temperatures and set the global hdd_temp to the highest #
function get_nvme_temp() {

    # Initialize the maximum hdd (NVMe) temperature variable (Absolute zero, Baby!)
    nvme_temp=-273

    # Each NVMe drive has multiple temp sensors, and there is no industry standard for
    #   the number of sensors or what each sensor monitors. So safest to check all
    #   temps and find the highest
    # Loop through all tempX_input entries in each of the hwmon_nvmeX variables
    declare -a details=()
    declare hwmon_nvme
    for hwmon_nvme in ${!all_hwmon_nvmes[@]}; do
        declare -a alltemps=()
        for temp_file in ${all_hwmon_nvmes[$hwmon_nvme]}/temp[0-9]*_input; do
            if [ -e "$temp_file" ]; then
                declare -i temp=$(<"$temp_file")
                # Print the raw value of each temp sensor if max debug is on
                debug 3 "Temperature value: $temp, NVMe variable: $hwmon_nvme, Temperature file: $temp_file"
                # round and scale to degrees
                (( temp = (temp+500)/1000 ))
                # track maximum value
                if [ $temp -gt $nvme_temp ]; then
                    nvme_temp=$temp
                fi
                alltemps+=($temp)
            fi
        done
        details+=("$hwmon_nvme=[${alltemps[*]}]")
    done

    debug 2 "GET_NVME_TEMP: $nvme_temp ( ${details[*]} )"
}

# query all drive temperatures and set the global hdd_temp to the highest
function get_hdd_temp() {

    hdd_temp=-273

    # presume we have up to 8 drives - find the highest temperature on them
    #
    # if you have an external HDD / m.2 sata ssd as the boot device you'll need to exclude it from the drive list so as to ignore it's temperature

    declare -a details=()
    for i in sda sdb sdc sdd sde sdf sdg sdh
    do
        # SMART attribute 194 is drive temperature
        temp=`smartctl -A /dev/$i | awk '$1 == "194" { print $10 }'`
        if [ -z $temp ]; then
            debug 3 "temp is NULL - drive does not exist"
        else
            details+=("$i=$temp")
            debug 3 "drive=$i temp=$temp"
            if [ $temp -gt $hdd_temp ]; then
                hdd_temp=$temp
                debug 3 "setting hdd_temp"
            fi
        fi
    done

    debug 2 "GET_HDD_TEMP:  $hdd_temp ( ${details[*]} )"
}

# query system temperatures and set the global sys_temp with the highest
function get_sys_temp() {

    # read the system board temp sensor via acpi
    local acpi_temp=$(<"$hwmon_acpi/temp1_input")
    (( acpi_temp= (acpi_temp+500) / 1000 ))

    # read all the temps available via coretemp ( pkg + core1..N ) and return the highest
    local cpu_temp=`cat $hwmon_coretemp/temp?_input | sort -nr | head -1`
    (( cpu_temp= (cpu_temp+500) / 1000 ))

    # choose the greatest of the core and system temps
    (( sys_temp= (acpi_temp > cpu_temp)? acpi_temp : cpu_temp ))

    debug 2 "GET_SYS_TEMP:  $sys_temp ( cpu=$cpu_temp acpi=$acpi_temp )"
}


# map the current nvme_temp to a desired pwm value
#
# we use base_pwm_value+sqr(hdd_temp-hdd_threshold)/1.8 to get a nice curve.
# I used 1.8 as the fudge factor to get max fan rpm at NVME temp of 60 degrees
#
function map_nvme_pwm() {
    if [[ $nvme_temp -le $nvme_threshold ]] ; then

        details="nvme_temp=$nvme_temp under threshold=$nvme_threshold"
        debug 3 "MAP_NVME_PWM: nvme temp=" $nvme_temp " and is under threshold"

        nvme_desired_pwm=$min_pwm

    else

        details="nvme_temp=$nvme_temp  OVER threshold=$nvme_threshold"
        debug 3 "MAP_NVME_PWM: nvme temp=" $nvme_temp " and is over threshold"

        # get the difference above threshold
        let nvme_desired_pwm=$nvme_temp-$nvme_threshold
        # fudge factor the difference
        let nvme_desired_pwm=$nvme_desired_pwm*10/18
        # square it
        let nvme_desired_pwm=$nvme_desired_pwm*$nvme_desired_pwm
        # add it to the base_pwm value
        let nvme_desired_pwm=$min_pwm+$nvme_desired_pwm

    fi

    if [[ $nvme_desired_pwm -gt 255 ]] ; then
        # over max - truncate to max
        nvme_desired_pwm=255
    fi

    debug 2 "MAP_NVME_PWM:    $nvme_desired_pwm ( $details )"
}

function map_hdd_pwm() {
    if [[ $hdd_temp -le $hdd_threshold ]] ; then

        details="hdd_temp=$hdd_temp under threshold=$hdd_threshold"
        debug 3 "MAP_HDD_PWM: hdd_temp=" $hdd_temp " and is under threshold"

        hdd_desired_pwm=$min_pwm

    else

        details="hdd_temp=$hdd_temp  OVER threshold=$hdd_threshold"
        debug 3 "MAP_HDD_PWM: hdd_temp=" $hdd_temp " and is over threshold"

        # get the difference above threshold
        let hdd_desired_pwm=$hdd_temp-$hdd_threshold
        # fudge factor the difference
        let hdd_desired_pwm=$hdd_desired_pwm*10/18
        # square it
        let hdd_desired_pwm=$hdd_desired_pwm*$hdd_desired_pwm
        # add it to the base_pwm value
        let hdd_desired_pwm=$min_pwm+$hdd_desired_pwm

    fi

    if [[ $hdd_desired_pwm -gt 255 ]] ; then
        # over max - truncate to max
        hdd_desired_pwm=255
    fi

    debug 2 "MAP_HDD_PWM:     $hdd_desired_pwm (  $details )"
}


# map the current sys_temp to a desired pwm value
#
# we use base_pwm_value+sqr((sys_temp-sys_threshold)/2) to get a nice curve
#
function map_sys_pwm() {
    if [[ $sys_temp -le $sys_threshold ]] ; then

        details="sys_temp=$sys_temp under threshold=$sys_threshold"
        debug 3 "MAP_SYS_PWM: sys_temp=" $sys_temp " and is under threshold"

        sys_desired_pwm=$min_pwm

    else

        details="sys_temp=$sys_temp  OVER threshold=$sys_threshold"
        debug 3 "MAP_SYS_PWM: sys_temp=" $sys_temp " and is over threshold"

        # get the difference above threshold
        let sys_desired_pwm=$sys_temp-$sys_threshold
        # halve the difference
        let sys_desired_pwm=$sys_desired_pwm/3
        # then square it
        let sys_desired_pwm=$sys_desired_pwm*$sys_desired_pwm
        # add it to the base pwm value
        let sys_desired_pwm=$min_pwm+$sys_desired_pwm

    fi

    if [[ $sys_desired_pwm -gt 255 ]] ; then
        # over max - truncate to max
        sdd_desired_pwm=255
    fi

    debug 2 "MAP_SYS_PWM:     $sys_desired_pwm (  $details )"
}


# determine desired zone based on current temp
function get_desired_pwm() {

    map_sys_pwm
    map_nvme_pwm
    map_hdd_pwm

    if [[ $nvme_desired_pwm -gt $sys_desired_pwm ]] && [[ $nvme_desired_pwm -gt $hdd_desired_pwm ]] ; then
        desired_pwm=$nvme_desired_pwm
        debug 2 "CHOOSE_PWM: nvme $desired_pwm ( nvme_pwm=$nvme_desired_pwm hdd_pwm=$hdd_desired_pwm sys_pwm=$sys_desired_pwm )"
    elif [[ $hdd_desired_pwm -gt $sys_desired_pwm ]] && [[ $hdd_desired_pwm -gt $nvme_desired_pwm ]] ; then
        desired_pwm=$hdd_desired_pwm
        debug 2 "CHOOSE_PWM:  hdd $desired_pwm ( nvme_pwm=$nvme_desired_pwm hdd_pwm=$hdd_desired_pwm sys_pwm=$sys_desired_pwm )"
    else
        desired_pwm=$sys_desired_pwm
        debug 2 "CHOOSE_PWM:  sys $desired_pwm ( nvme_pwm=$nvme_desired_pwm hdd_pwm=$hdd_desired_pwm sys_pwm=$sys_desired_pwm )"
    fi
}

## MAIN #################################################################################

# get initial temperatures

debug 2 "--------------------------------------------"

get_fan_rpm
get_sys_temp
get_nvme_temp
get_hdd_temp

last_sys_temp=$sys_temp
last_nvme_temp=$nvme_temp
last_hdd_temp=$hdd_temp

# we use the variables 'last_pwm' 'last_sys_temp' and 'last_hdd_temp' to track what the pwm/temps values were last time
# through the loop - so we only change the fan speeds when there's a state change  as opposed to every iteration

# get initial pwm value

get_desired_pwm

last_pwm=$desired_pwm

# set initial fan speed

debug 2 "MAIN: initial fan pwm=$desired_pwm"

set_fan_pwm $desired_pwm

# now loop forever monitoring and reacting

cycles=$ratio_sys_to_hdd

while true; do

    # update sensor readings
    debug 2 "--------------------------------------------"

    get_fan_rpm
    get_sys_temp
    get_nvme_temp

    if [[ $cycles -eq 1 ]] ; then

       debug 3 "MAIN: sampling hdd sensor"

       get_hdd_temp
       cycles=$ratio_sys_to_hdd

    else

        debug 2 "GET_HDD_TEMP:  $hdd_temp ( skipped update )"

        let cycles=$cycles-1

    fi

    # update target pwm value based on readings

    get_desired_pwm

    debug 2 "MAIN: current/last desired_pwm=$desired_pwm/$last_pwm sys_temp=$sys_temp/$last_sys_temp nvme_temp=$nvme_temp/$last_nvme_temp hdd_temp=$hdd_temp/$last_hdd_temp fan_rpm=$fan_rpm"
    #if [[ $debugLvl -gt 1 ]] ; then
        #echo "MAIN: desired_pwm=" $desired_pwm " last_pwm=" $last_pwm
        #echo "MAIN: sys_temp=" $sys_temp " last_sys_temp=" $last_sys_temp
        #echo "MAIN: nvme_temp=" $nvme_temp " last_nvme_temp=" $last_nvme_temp
        #echo "MAIN: hdd_temp=" $hdd_temp " last_hdd_temp=" $last_hdd_temp
        #echo "MAIN: fan_rpm=" $fan_rpm
    #fi

    if [[ $desired_pwm -gt $last_pwm ]] ; then
       # fan speed increase desired - react immediately

       debug 1 "****: fan INCREASE pwm=$desired_pwm (nvme_temp=$nvme_temp hdd_temp=$hdd_temp sys_temp=$sys_temp fan_rpm=$fan_rpm)"

       if [[ $mailalerts -ge 1 ]] ; then
          echo "****: fan INCREASE pwm=$desired_pwm (nvme_temp=$nvme_temp hdd_temp=$hdd_temp sys_temp=$sys_temp fan_rpm=$fan_rpm)" | mail $mail_address -s "$mail_name - temperature alert"
       fi

       # set the fan speed

       set_fan_pwm $desired_pwm

       # update state tracking variables ONLY when there's a change in the target fan speed

       last_pwm=$desired_pwm
       last_sys_temp=$sys_temp
       last_nvme_temp=$nvme_temp
       last_hdd_temp=$hdd_temp
    fi

    if [[ $desired_pwm -lt $last_pwm ]] ; then
        # fan speed decrease desired

        # calculate deltas from last reading for each sensor

        let nvme_delta=$last_nvme_temp-$nvme_temp
        let hdd_delta=$last_hdd_temp-$hdd_temp
        let sys_delta=$last_sys_temp-$sys_temp

        debug 2 "MAIN: current sys_delta=$sys_delta current nvme_delta=$nvme_delta current hdd_delta=$hdd_delta"

        # we need to apply some degree of hysteresis on hdd_temp and sys_temp to prevent fan speed hunting,
        # variables defined at the start of the script

        if [[ $nvme_delta -gt $nvme_delta_threshold ]] || [[ $hdd_delta -gt $hdd_delta_threshold ]] || [[ $sys_delta -gt $sys_delta_threshold ]]; then

            # we've got sufficient downward temp delta - actually change the fan speed

            debug 1 "****: fan DECREASE pwm=$desired_pwm (nvme_temp=$nvme_temp hdd_temp=$hdd_temp sys_temp=$sys_temp fan_rpm=$fan_rpm)"

            if [[ $mailalerts -ge 1 ]] ; then
                echo "****: fan DECREASE pwm=$desired_pwm (nvme_temp=$nvme_temp hdd_temp=$hdd_temp sys_temp=$sys_temp fan_rpm=$fan_rpm)" | mail $mail_address -s "$mail_name - temperature alert"
            fi

            # set the fan speed

            set_fan_pwm $desired_pwm

            # update state tracking variables ONLY when there's a change in the target fan speed

            last_pwm=$desired_pwm
            last_sys_temp=$sys_temp
            last_nvme_temp=$nvme_temp
            last_hdd_temp=$hdd_temp

        else

            # not enough downward delta to trigger an actual change yet

            debug 1 "****: fan PENDING  pwm=$desired_pwm (nvme_temp=$nvme_temp hdd_temp=$hdd_temp sys_temp=$sys_temp fan_rpm=$fan_rpm) - not enough delta ( $sys_delta $nvme_delta $hdd_delta ) yet!"
        fi
    fi

    debug 2 "MAIN: sleeping for $frequency seconds"
    sleep $frequency

done
