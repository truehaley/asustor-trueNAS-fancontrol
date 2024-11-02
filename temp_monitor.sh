#!/bin/bash

# Asustor Flashstor6 and Flashstor12 Pro fan control script for TrueNAS-SCALE 22
#
# Run me as a post-init command:
#   nohup /home/truenas_admin/bin/temp_monitor.sh > /dev/null &
# Desired debug output level (set below as debugLvl) will be written to /var/log/syslog

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


# uses sqr(temp above threshold/3)+base_pwm for cpu/sys response curve
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
declare -r debugLvl=1
# When debug output level is 1, only log output every "idleDebugInterval" seconds
declare -r idle_debug_interval=30

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
if [[ $mailalerts -ge 1 ]] ; then
    debug 2 "STARTUP: mail_address=$mail_address mail_hostname=$mail_hostname"
else
    debug 2 "STARTUP: no mail alerts configured"
fi

# how often we check temps / set speed ( in seconds )
declare -r check_interval=10

# how often we update hdd sensors ( in seconds )
# (sampling the sys and nvme sensors is lightweight, whereas querying the hdd sensors via SMART disrupts disk i/o - and hdd temp doesn't change that fast)
declare -r hdd_check_interval=120


# minimum pwm value we want the fan to run at
# Stats     Noctua NF-P12   Stock SAB4B2U
#   70          550             1000
#   100         760
#   110         830
#   140         1000
#   200         1415
#   255         1730
declare -r min_pwm=140

# Minimum PWM setting (above) should keep all temperatures below their target temps when system is at idle
# Any temperature read above the max temp will cause fans to operate at full speed
declare -r sys_target_temp=50
declare -r sys_max_temp=85      # documented limit for N5105 is 105
declare -r nvme_target_temp=32
declare -r nvme_max_temp=50     # documented limit for crucial p3 plus is 70
declare -r hdd_target_temp=38
declare -r hdd_max_temp=50      # documented limit for seagate ironwolf is 65

# Scale factors are roughly determied by:  (max_temp-target_temp)*10 / sqrt(255-min_pwm)
declare -r sys_scale_factor=32
declare -r nvme_scale_factor=16
declare -r hdd_scale_factor=11


# How much of a temp change do we look for before altering fan speeds so we limit fan hunting
declare -r nvme_delta_threshold=2
declare -r hdd_delta_threshold=2
declare -r sys_delta_threshold=4


#### determine the /sys/class/hwmon mappings ####
debug 1 "STARTUP: Fan control:"
# which /sys/class/hwmon symlink points to the asustor_it87 ( fan speed )
declare -r hwmon_it87="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i it87 | cut -d "\"" -f 2`
debug 1 "STARTUP:   hwmon_it87=$hwmon_it87"

debug 1 "STARTUP: System monitoring:"
# which /sys/class/hwmon symlink points to the intel coretemp sensors
declare -r hwmon_coretemp="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i coretemp | cut -d "\"" -f 2`
debug 1 "STARTUP:   hwmon_coretemp=$hwmon_coretemp"

# which /sys/class/hwmon symlink points to the acpi sensors ( board temperature sensor )
declare -r hwmon_acpi="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i thermal_zone0 | cut -d "\"" -f 2`
debug 1 "STARTUP:   hwmon_acpi=$hwmon_acpi"


# Use an array to find which /sys/class/hwmon symlinks point to the NVMe drive sensors and assign them sequential variables
#    This should find all NVMe drives regardless of the number installed, and assign them to
#    sequential variables hwmon_nvme1, hwmon_nvme2 ... hwmon_nvme(x)
debug 1 "STARTUP: NVMe hardware monitoring devices:"
declare -A all_hwmon_nvmes=()
while read -r path; do
    declare current_nvme="nvme${#all_hwmon_nvmes[*]}"
    all_hwmon_nvmes[$current_nvme]="/sys/class/hwmon/$path"
    debug 1 "STARTUP:   $current_nvme=/sys/class/hwmon/$path"
done < <(ls -lQ /sys/class/hwmon | grep -i nvme | cut -d "\"" -f 2)

# The following will find all direct-attached sata interface drives, it will not include usb sticks
debug 2 "STARTUP: HDD drives:"
declare -A all_hdds=()
while read -r current_hdd; do
    all_hdds[$current_hdd]="/dev/$current_hdd"
    debug 1 "STARTUP:   $current_hdd=/dev/$current_hdd"
done < <(lsblk -SP | grep -i sata | cut -d "\"" -f 2)


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
    fan_pwm=$(<"$hwmon_it87/pwm1")
    debug 2 "FAN  PWM: $fan_pwm  RPM:  $fan_rpm"
}

# map current temp to desired pwm values
# we use min_pwm+sqr((temp-target)*10/scale_factor) to get a nice curve that ramps more quickly toward
#   max pwm as we approach the max temp (assuming scale factors are set correctly above)
function scale_pwm () {
    # reference appropriate global vars based on function parameter of "sys" "hdd" or "nvme"
    declare -n temp="$1_temp"
    declare -n target="$1_target_temp"
    declare -n max="$1_max_temp"
    declare -n thresh_details="$1_thresh_details"
    declare -n desired_pwm="$1_desired_pwm"
    declare -n scale="$1_scale_factor"

    if [[ $temp -le $target ]] ; then
        thresh_details="$temp < $target "
        desired_pwm=$min_pwm
    elif [[ $temp -ge $max ]] ; then
        thresh_details="$temp > $max!"
        desired_pwm=255
    else
        thresh_details="$temp > $target "

        # get the amount above target and apply the scale factor
        (( desired_pwm = (temp-target)*10/scale ))
        # square and add to the base_pwm value
        (( desired_pwm = desired_pwm*desired_pwm + min_pwm ))
        # max value 255
        (( desired_pwm = (desired_pwm > 255)? 255: desired_pwm ))
    fi
}


# query system temperatures and set the global sys_temp with the highest, them map to desired pwm value
function get_sys() {

    # read the system board temp sensor via acpi
    declare -i acpi_temp=$(<"$hwmon_acpi/temp1_input")
    (( acpi_temp= (acpi_temp+500) / 1000 ))

    # read all the temps available via coretemp ( pkg + core1..N ) and return the highest
    declare -i cpu_temp=`cat $hwmon_coretemp/temp?_input | sort -nr | head -1`
    (( cpu_temp= (cpu_temp+500) / 1000 ))

    # choose the greatest of the core and system temps
    (( sys_temp= (acpi_temp > cpu_temp)? acpi_temp : cpu_temp ))

    scale_pwm "sys"

    debug 2 "SYS  PWM: $sys_desired_pwm  TEMP: $sys_thresh_details LAST: $last_sys_temp ( cpu=$cpu_temp acpi=$acpi_temp )"
}


# query all NVMe drive temperatures and set the global hdd_temp to the highest #, then map to desired pwm value
function get_nvme() {

    # Initialize the maximum hdd (NVMe) temperature variable (Absolute zero, Baby!)
    nvme_temp=-273

    # Each NVMe drive has multiple temp sensors, and there is no industry standard for
    #   the number of sensors or what each sensor monitors. So safest to check all
    #   temps and find the highest
    # Loop through all tempX_input entries in each of the hwmon_nvmeX variables
    declare -a nvme_details=()
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
                (( nvme_temp = ( temp>nvme_temp )? temp : nvme_temp ))
                alltemps+=($temp)
            fi
        done
        nvme_details+=("$hwmon_nvme=[${alltemps[*]}]")
    done

    scale_pwm "nvme"

    debug 2 "NVME PWM: $nvme_desired_pwm  TEMP: $nvme_thresh_details LAST: $last_nvme_temp ( ${nvme_details[*]} )"
}


# query all drive temperatures and set the global hdd_temp to the highest
# but only actually query the drives once in sys_to_hd cycles to avoid interrupting any IO
hdd_elapsed=0
# map the current hdd_temp to a desired pwm value
# we use base_pwm_value+sqr(hdd_temp-hdd_threshold)/1.8 to get a nice curve.
# I used 1.8 as the fudge factor to get max fan rpm at HDD temp of 60 degrees
function get_hdd() {
    declare -a hdd_details=()

    if [[ $hdd_elapsed -lt $check_interval ]] ; then
        hdd_elapsed=$hdd_check_interval

        hdd_temp=-273
        for hdd in ${!all_hdds[@]}; do
            # SMART attribute 194 is drive temperature
            declare hdd_path=${all_hdds[$hdd]}
            temp=`smartctl -A $hdd_path | awk '$1 == "194" { print $10 }'`
            if [ -z $temp ]; then
                debug 3 "temp is NULL - drive does not exist"
            else
                hdd_details+=("$hdd=$temp")
                debug 3 "drive=$i temp=$temp"
                if [ $temp -gt $hdd_temp ]; then
                    hdd_temp=$temp
                    debug 3 "setting hdd_temp"
                fi
            fi
        done
    else
        (( hdd_elapsed -= check_interval ))
        hdd_details+="skipped update"
    fi

    scale_pwm "hdd"

    debug 2 "HDD  PWM: $hdd_desired_pwm  TEMP: $hdd_thresh_details LAST: $last_hdd_temp ( ${hdd_details[*]} )"
}


# determine desired zone based on current temp
function get_desired_pwm() {
    declare selected_pwm
    if [[ $nvme_desired_pwm -gt $sys_desired_pwm ]] && [[ $nvme_desired_pwm -gt $hdd_desired_pwm ]] ; then
        desired_pwm=$nvme_desired_pwm
        selected_pwm="nvme"
        full_thresh_details="  SYS: $sys_thresh_details [NVME: $nvme_thresh_details] HDD: $hdd_thresh_details "
    elif [[ $hdd_desired_pwm -gt $sys_desired_pwm ]] && [[ $hdd_desired_pwm -gt $nvme_desired_pwm ]] ; then
        desired_pwm=$hdd_desired_pwm
        selected_pwm=" hdd"
        full_thresh_details="  SYS: $sys_thresh_details  NVME: $nvme_thresh_details [HDD: $hdd_thresh_details]"
    elif [[ $sys_desired_pwm -gt $nvme_desired_pwm ]] && [[ $sys_desired_pwm -gt $hdd_desired_pwm ]] ; then
        desired_pwm=$sys_desired_pwm
        selected_pwm=" sys"
        full_thresh_details=" [SYS: $sys_thresh_details] NVME: $nvme_thresh_details  HDD: $hdd_thresh_details "
    else
        # they are all the same level
        desired_pwm=$sys_desired_pwm
        selected_pwm=" sys"
        if [[ $desired_pwm -gt $min_pwm ]]; then
            # all high!
            full_thresh_details=" [SYS: $sys_thresh_details  NVME: $nvme_thresh_details  HDD: $hdd_thresh_details]"
        else
            # idle
            full_thresh_details="  SYS: $sys_thresh_details  NVME: $nvme_thresh_details  HDD: $hdd_thresh_details "
        fi
    fi
    debug 3 "CHOOSE_PWM: $selected_pwm $desired_pwm ( sys_pwm=$sys_desired_pwm nvme_pwm=$nvme_desired_pwm hdd_pwm=$hdd_desired_pwm )"

}

## MAIN #################################################################################

# get initial temperatures

debug 2 "--------------------------------------------"

# we use the variables 'last_pwm' 'last_sys_temp' and 'last_hdd_temp' to track what the pwm/temps values were last time
# through the loop - so we only change the fan speeds when there's a state change as opposed to every iteration
last_sys_temp=0
last_nvme_temp=0
last_hdd_temp=0
# how long until our next idle debug report
idle_elapsed=0

get_fan_rpm
get_sys
get_nvme
get_hdd
last_sys_temp=$sys_temp
last_nvme_temp=$nvme_temp
last_hdd_temp=$hdd_temp

# get initial pwm value
get_desired_pwm
last_pwm=$desired_pwm

# set initial fan speed
set_fan_pwm $desired_pwm
debug 2 "MAIN: initial fan pwm=$desired_pwm"

# now loop forever monitoring and reacting
while true; do

    # update sensor readings
    debug 2 "--------------------------------------------"

    get_fan_rpm
    get_sys
    get_nvme
    get_hdd

    # update target pwm value based on readings
    get_desired_pwm

    #debug 2 "MAIN: current/last desired_pwm=$desired_pwm/$last_pwm sys_temp=$sys_temp/$last_sys_temp nvme_temp=$nvme_temp/$last_nvme_temp hdd_temp=$hdd_temp/$last_hdd_temp fan_rpm=$fan_rpm"

    if [[ $desired_pwm -gt $last_pwm ]] ; then
       # fan speed increase desired - react immediately

       debug 1 "PWM: ${desired_pwm}+  LAST RPM: $fan_rpm   TEMPS: $full_thresh_details"
       idle_elapsed=0

       if [[ $mailalerts -ge 1 ]] ; then
          echo "****: fan INCREASE pwm=$desired_pwm ( nvme_temp=$nvme_temp hdd_temp=$hdd_temp sys_temp=$sys_temp fan_rpm=$fan_rpm )" | mail $mail_address -s "$mail_name - temperature alert"
       fi

       # set the fan speed
       set_fan_pwm $desired_pwm

       # update state tracking variables ONLY when there's a change in the target fan speed
       last_pwm=$desired_pwm
       last_sys_temp=$sys_temp
       last_nvme_temp=$nvme_temp
       last_hdd_temp=$hdd_temp
    elif [[ $desired_pwm -lt $last_pwm ]] ; then
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

            debug 1 "PWM: ${desired_pwm}-  LAST RPM: $fan_rpm   TEMPS: $full_thresh_details"
            idle_elapsed=0

            if [[ $mailalerts -ge 1 ]] ; then
                echo "****: fan DECREASE pwm=$desired_pwm ( nvme_temp=$nvme_temp hdd_temp=$hdd_temp sys_temp=$sys_temp fan_rpm=$fan_rpm )" | mail $mail_address -s "$mail_name - temperature alert"
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

            debug 1 "PWM: ${desired_pwm}~  LAST RPM: $fan_rpm   TEMPS: $full_thresh_details"
            idle_elapsed=0
        fi
    else
        if [[ $desired_pwm -gt $min_pwm ]] || [[ $debugLvl -ge 2 ]]; then
            # always output when pwm is above min or debugLvl is 2 or more
            idle_elapsed=0
        fi
        if [[ $idle_elapsed -le $check_interval ]]; then
            debug 1 "PWM: ${desired_pwm}   LAST RPM: $fan_rpm   TEMPS: $full_thresh_details"
            idle_elapsed=$idle_debug_interval
        else
            (( idle_elapsed -= check_interval ))
        fi
    fi

    debug 3 "MAIN: sleeping for $check_interval seconds"
    sleep $check_interval

done
