#! /bin/bash

###############################################################################
#
#   Adapted from the work Scott Emery has shared at
#   https://community.ubnt.com/t5/mFi/bash-script-for-controlling-mFi-devices/td-p/1495067
#
#   mfictrl - Control Ubiquiti mFi devices
#
#   Description: This script allows for the control of Ubiquiti mFi devices.
#   Given the IP address (or DNS name) of a device, the script will control 
#   the device (turn it on [with dim level], off) or return the current status
#   of the device.
#
###############################################################################

MFICTRL_SCRIPT_VERSION="1.0a"
base=$(/usr/bin/basename $0)

# Default variables
USERNAME="ubnt"
PASSWORD="ubnt"
PORT="1"
MFI_SESSION_ID=""

#------------------------------------------------------------------------------
#
#   Functions used by the script
#
#------------------------------------------------------------------------------

#
#   This function prints usage information for this script
#

mfictrl_usage()
{
    help_message=$(/bin/cat <<EOF
    NAME
        ${base} - Control a Ubiquiti mFi device

    VERSION
        ${MFICTRL_SCRIPT_VERSION}

    SYNOPSIS
        ${base} [-h] [-p PORT] [-v] [-l] <device_ip> ON [<dim%>] | OFF | STATUS

    DESCRIPTION
        ${base} is used to control a Ubiquiti mFi device. The device can be
        turned on, turned off, or the current status of the device can be
        returned. 

    OPTIONS
        -h      Help. Displays this message

        -p PORT Uses the specified PORT on the device. If not supplied the
                default of port 1 will be used.

        -v      Verbose. Print debugging output

        -l      Print a message after command completion.

        -u USERNAME The user name to login to the mFi device

        -a PASSWORD The password to login to the mFi device

        <device_ip> 
                The IP address of the device which is being controlled. This
                can also be a DNS name if one has been defined. 

        ON [<dim>] | OFF | STATUS 
                The command to execute. ON turns the device on at the specified
                dim level (or 100% if not specified). OFF turns the device off,
                and STATUS retrieves the current state of the device.

EOF
)
    echo "${help_message}\n" >&2
}

#
#   This function prints its parameters if the verbose flag is set.
#

verbose_log()
{
    if [ -n "${VERBOSE}" ]
    then
        echo -e $@ >&2
    fi
}

#
#   This function sets the global MFI_SESSION_ID variable to a random value. The
#   session ID must be 32 decimal digits.
#

get_random_session_id()
{
    # Loop 8 times, getting 4 random digits each time.
    MFI_SESSION_ID=""
    for quad in {1..8}
    do
        MFI_SESSION_ID+=$(printf %04d $(( $RANDOM % 10000 )) )
    done
}

#
#   This function logs into the mFi device
#
#   Usage: mfi_login USERNAME PASSWORD SESSION_ID IP_ADDR
#

mfi_login()
{
    local USERNAME=${1}
    local PASSWORD=${2}
    local SESSION_ID=${3}
    local IP_ADDR=${4}

    verbose_log "Calling mfi_login with USERNAME=${USERNAME} PASSWORD=${PASSWORD} SESSION_ID=${SESSION_ID} IP_ADDR=${IP_ADDR}" 

    # Login to the device
    /usr/bin/curl \
        -X POST \
        -s \
        -d 'username='${USERNAME}'&password='${PASSWORD} \
        -b 'AIROS_SESSIONID='${SESSION_ID} \
        ${IP_ADDR}/login.cgi

    # Everything OK? Check the curl return code.
    local STATUS=$?
    if [ ${STATUS} -ne 0 ]
    then
        echo "Login to ${IP_ADDR} ${USERNAME}:${PASSWORD} session ${SESSION_ID} failed with code ${STATUS}"
        exit ${STATUS}
    fi
}

#
#   This function logs out of the mFi device
#
#   Usage: mfi_logout SESSION_ID IP_ADDR
#

mfi_logout()
{
    local SESSION_ID=${1}
    local IP_ADDR=${2}

    verbose_log "Calling mfi_logout with SESSION_ID=${SESSION_ID} IP_ADDR=${IP_ADDR}" 

    # Log out of the device
    /usr/bin/curl \
        -s \
        -b 'AIROS_SESSIONID='${SESSION_ID} \
        ${IP_ADDR}/logout.cgi

    # Everything OK? Check the curl return code.
    local STATUS=$?
    if [ ${STATUS} -ne 0 ]
    then
        echo "Logout from ${IP_ADDR} ${SESSION_ID} failed with code ${STATUS}"
        exit ${STATUS}
    fi
}

#
#   This function gets the status of a device. The status is returned in the
#   MFI_OUTPUT (0 or 1), MFI_DIM_LEVEL (0-100), and MFI_SWITCH_MODE ("switch" or
#   "dimmer") global variables.
#
#   Usage: mfi_get_status SESSION_ID IP_ADDR PORT
#
#   Typical JSON output from the switch has a format similar to this. The 'jq'
#   command is used to parse this information:
#
#   {
#       "sensors": [
#           {
#               "current": 0.0,
#               "dimmer_level": 50,
#               "dimmer_mode": "dimmer",
#               "enabled": 0,
#               "lock": 0,
#               "output": 0,
#               "port": 1,
#               "power": 0.0,
#               "powerfactor": 0.0,
#               "prevmonth": 174253,
#               "relay": 0,
#               "thismonth": 44846,
#               "voltage": 122.882881164
#           }
#       ],
#       "status": "success"
#   }
#

mfi_get_status()
{
    local SESSION_ID=${1}
    local IP_ADDR=${2}
    local PORT=${3}

    verbose_log "Calling mfi_get_status with SESSION_ID=${SESSION_ID} IP_ADDR=${IP_ADDR} PORT=${PORT}" 

    # Get the status from the device
    local STATUS_JSON=$(/usr/bin/curl \
        -s \
        -b 'AIROS_SESSIONID='${SESSION_ID} \
        ${IP_ADDR}/sensors)

    # Everything OK? Check both curl return code and JSON output
    local STATUS=$?
    if [ ${STATUS} -ne 0 ]
    then
        echo "Status retrieval from ${IP_ADDR} ${SESSION_ID} failed with code ${STATUS}"
        mfi_logout ${SESSION_ID} ${IP_ADDR}
        exit ${STATUS}
    fi

    local JSON_STATUS=$(/usr/bin/jq '.status' <<< ${STATUS_JSON})
    if [ ${JSON_STATUS} != "\"success\"" ]
    then
        echo "Status in JSON output was not success: ${JSON_STATUS}. Retrieval from ${IP_ADDR} ${SESSION_ID} failed."
        mfi_logout ${SESSION_ID} ${IP_ADDR}
        exit -1
    fi

    # Get the output value for the selected port
    MFI_OUTPUT=$(/usr/bin/jq \
        '.sensors[]? as $sensor |
        if $sensor.port == '"${PORT}"' then $sensor.output
        else empty end' <<< ${STATUS_JSON})

    # Get the dimmer_level value for the selected port
    MFI_DIM_LEVEL=$(/usr/bin/jq \
        '.sensors[]? as $sensor |
        if $sensor.port == '"${PORT}"' then $sensor.dimmer_level
        else empty end' <<< ${STATUS_JSON})

    # Get the dimmer_mode value for the selected port
    MFI_SWITCH_MODE=$(/usr/bin/jq \
        '.sensors[]? as $sensor |
        if $sensor.port == '"${PORT}"' then $sensor.dimmer_mode
        else empty end' <<< ${STATUS_JSON})

    # If the dimmer_mode is "switch" then displayed DIM_LEVEL is 100% 
    local DISPLAYED_DIM_LEVEL=${MFI_DIM_LEVEL}
    [ ${MFI_SWITCH_MODE} == "\"switch\"" ] && DISPLAYED_DIM_LEVEL=100

    # If the dimmer_mode is not "switch" then lights are only mostly off
    local DISPLAYED_EXTRA_INFO
    [ ${MFI_SWITCH_MODE} != "\"switch\"" ] && DISPLAYED_EXTRA_INFO=" (mostly)"

    # Print out a message about the current status
    if [ ${MFI_OUTPUT} -ne 0 ]
    then
        echo `date` ": The mFi ${DEV_IP} port ${PORT} is now ON."
    else
        echo `date` ": The mFi ${DEV_IP} port ${PORT} is now OFF"
    fi
}

#
#   This function turns on a device
#
#   Usage: mfi_turn_on SESSION_ID IP_ADDR PORT DIMMER_LEVEL
#

mfi_turn_on()
{
    local SESSION_ID=${1}
    local IP_ADDR=${2}
    local PORT=${3}
    local DIMMER_LEVEL=${4}

    verbose_log "Calling mfi_turn_on with SESSION_ID=${SESSION_ID} IP_ADDR=${IP_ADDR} PORT=${PORT} DIMMER_LEVEL=${DIMMER_LEVEL}" 

    # Turn the device on by ensuring switch mode, and turning on output and the relay
    local PUT_JSON=$(/usr/bin/curl \
        -X PUT \
        -s \
        -d 'dimmer_mode=switch' \
        -b 'AIROS_SESSIONID='${SESSION_ID} \
        ${IP_ADDR}/sensors/${PORT})

    local PUT_JSON=$(/usr/bin/curl \
        -X PUT \
        -s \
        -d 'output=1&relay=1' \
        -b 'AIROS_SESSIONID='${SESSION_ID} \
        ${IP_ADDR}/sensors/${PORT})

    # Everything OK? Check both curl return code and JSON output
    local STATUS=$?
    if [ ${STATUS} -ne 0 ]
    then
        echo "Turning on ${IP_ADDR} with session ${SESSION_ID} failed with code ${STATUS}"
        mfi_logout ${SESSION_ID} ${IP_ADDR}
        exit ${STATUS}
    fi

    local JSON_STATUS=$(/usr/bin/jq '.status' <<< ${PUT_JSON})
    if [ ${JSON_STATUS} != "\"success\"" ]
    then
        echo "Status in JSON output was not success: ${JSON_STATUS}. Turning on ${IP_ADDR} ${SESSION_ID} failed."
        mfi_logout ${SESSION_ID} ${IP_ADDR}
        exit -1
    fi

}

#
#   This function turns off a device
#
#   Usage: mfi_turn_off SESSION_ID IP_ADDR PORT
#

mfi_turn_off()
{
    local SESSION_ID=${1}
    local IP_ADDR=${2}
    local PORT=${3}

    verbose_log "Calling mfi_turn_off with SESSION_ID=${SESSION_ID} IP_ADDR=${IP_ADDR} PORT=${PORT}" 

    # Turn the device off by ensuring switch mode, and turning off output and the relay
    local PUT_JSON=$(/usr/bin/curl \
        -X PUT \
        -s \
        -d 'dimmer_mode=switch' \
        -b 'AIROS_SESSIONID='${SESSION_ID} \
        ${IP_ADDR}/sensors/${PORT})

    local PUT_JSON=$(/usr/bin/curl \
        -X PUT \
        -s \
        -d 'output=0&relay=0' \
        -b 'AIROS_SESSIONID='${SESSION_ID} \
        ${IP_ADDR}/sensors/${PORT})

    # Everything OK? Check both curl return code and JSON output
    local STATUS=$?
    if [ ${STATUS} -ne 0 ]
    then
        echo "Turning off ${IP_ADDR} with session ${SESSION_ID} failed with code ${STATUS}"
        mfi_logout ${SESSION_ID} ${IP_ADDR}
        exit ${STATUS}
    fi

    verbose_log "The JSON output is: ${PUT_JSON}"
    local JSON_STATUS=$(/usr/bin/jq '.status' <<< ${PUT_JSON})
    if [ ${JSON_STATUS} != "\"success\"" ]
    then
        echo "Status in JSON output was not success: ${JSON_STATUS}. Turning off ${IP_ADDR} ${SESSION_ID} failed."
        mfi_logout ${SESSION_ID} ${IP_ADDR}
        exit -1
    fi

}

#------------------------------------------------------------------------------
#
#   Script execution begins here
#
#------------------------------------------------------------------------------

#
#   Parse command line options
#

cl_args="hvlp:u:a:"
while getopts "${cl_args}" a ; do
    case $a in
        h)  mfictrl_usage
            exit 0
            ;;
        v)  VERBOSE=1
            ;;
        l)  LOGMSG=1
            ;;
        p)  PORT=${OPTARG}
            ;;
        u)  USERNAME=${OPTARG}
            ;;
        a)  PASSWORD=${OPTARG}
            ;;
        \?) mfictrl_usage
            echo "*** The command line option -${OPTARG} is not recognized and will be ignored" >&2
            ;;
        :)  mfictrl_usage
            echo "*** The command line option ${OPTARG} requires an argument" >&2
            exit 1
            ;;
    esac
done
shift $(($OPTIND-1))

#
#   Get the IP address and operation
#

DEV_IP=${1}
shift 1
if [ -z "${DEV_IP}" ]
then
    mfictrl_usage
    echo "*** An IP address or DNS name of the mFi device is required." >&2
    exit 1
fi

OPERATION=${1}
shift 1
if [ -z "${OPERATION}" ]
then
    mfictrl_usage
    echo "*** An operation to perform (ON, OFF, STATUS) is required." >&2
    exit 1
fi

#
#   Perform the requested operation
#

get_random_session_id
mfi_login ${USERNAME} ${PASSWORD} ${MFI_SESSION_ID} ${DEV_IP}
case ${OPERATION} in

    STATUS|status)
        verbose_log "Executing STATUS command"
        mfi_get_status ${MFI_SESSION_ID} ${DEV_IP} ${PORT}
        ;;
    ON|on)
        DIM_LEVEL=$1
        shift 1
        if [ -z "${DIM_LEVEL}" ]
        then
            DIM_LEVEL=100
        fi
        verbose_log "Executing ON ${DIM_LEVEL} command"
        mfi_turn_on ${MFI_SESSION_ID} ${DEV_IP} ${PORT} ${DIM_LEVEL}
        if [ -n "${LOGMSG}" ]
        then
            mfi_get_status ${MFI_SESSION_ID} ${DEV_IP} ${PORT}
        fi
        ;;
    OFF|off)
        verbose_log "Executing OFF command"
        mfi_turn_off ${MFI_SESSION_ID} ${DEV_IP} ${PORT}
        if [ -n "${LOGMSG}" ]
        then
            mfi_get_status ${MFI_SESSION_ID} ${DEV_IP} ${PORT}
        fi
        ;;
    *)
        echo "Unsupported operation: ${OPERATION}" >&2
        mfi_logout ${MFI_SESSION_ID} ${DEV_IP}
        exit 1
        ;;

esac
mfi_logout ${MFI_SESSION_ID} ${DEV_IP}