#!/usr/bin/env bash
#
# A FRITZ!-based HomeMatic presence detection script which can be regularly
# executed (e.g. via cron on a separate Linux system) and remotely queries a FRITZ!
# device about the registered LAN/WLAN devices.
#
# This script can be found at https://github.com/jens-maus/hm_pdetect
#
# Based on a device list specified in the config file (HM_USER_LIST) certain system
# variables are then set in the corresponding CCU so that users are being recognized
# as being present or away. In addition guests are being identified by also specifying
# other known devices in a separate list (HM_KNOWN_LIST) and if a device is found
# that is not either in the user list or known list it will be recognized as a
# guest device and the script will set a presence system variable for guests in the
# CCU as well.
#
# Copyright (C) 2015-2017 Jens Maus <mail@jens-maus.de>
#
# This script is based on similar functionality and combines the functionality of
# these projects into a single script:
#
# https://github.com/jollyjinx/homematic
# https://github.com/max2play/webinterface
#

VERSION="1.3"
VERSION_DATE="Aug 30 2017"

#####################################################
# Main script starts here, don't modify from here on

# before we read in default values we have to find
# out which HM_* variables the user might have specified
# on the command-line himself
USERVARS=$(set -o posix; set | grep "HM_.*=" 2>/dev/null)

# IP addresses/hostnames of LANCOM! devices
HM_LANCOM_IP=${HM_LANCOM_IP:-"lancom"}

# IP address/hostname of CCU2
HM_CCU_IP=${HM_CCU_IP:-"ccu3-webui"}

# Name of the CCU variable prefix used
HM_CCU_PRESENCE_VAR=${HM_CCU_PRESENCE_VAR:-"Anwesenheit"}

# used names (user definable)
HM_CCU_PRESENCE_USER=${HM_CCU_PRESENCE_USER:-"Nutzer"}
HM_CCU_PRESENCE_USER_ENABLED=${HM_CCU_PRESENCE_USER_ENABLED:-true}
HM_CCU_PRESENCE_GUEST=${HM_CCU_PRESENCE_GUEST:-"Gast"}
HM_CCU_PRESENCE_GUEST_ENABLED=${HM_CCU_PRESENCE_GUEST_ENABLED:-true}
HM_CCU_PRESENCE_LIST=${HM_CCU_PRESENCE_LIST:-"list"}
HM_CCU_PRESENCE_LIST_ENABLED=${HM_CCU_PRESENCE_LIST_ENABLED:-true}
HM_CCU_PRESENCE_STR=${HM_CCU_PRESENCE_STR:-"string"}
HM_CCU_PRESENCE_STR_ENABLED=${HM_CCU_PRESENCE_STR_ENABLED:-true}

# used names for variable values
HM_CCU_PRESENCE_NOBODY=${HM_CCU_PRESENCE_NOBODY:-"Niemand"}
HM_CCU_PRESENCE_PRESENT=${HM_CCU_PRESENCE_PRESENT:-"anwesend"}
HM_CCU_PRESENCE_AWAY=${HM_CCU_PRESENCE_AWAY:-"abwesend"}

# Specify mode of HM_KNOWN_LIST variable setting
#
# guest - apply known ignore list to devices in a dedicated
#         guest WiFi/LAN only (requireѕ enabled guest WiFi/LAN in
#         LANCOM! device)
# all   - apply known ignore list to all devices
# off   - disabled guest recognition
HM_KNOWN_LIST_MODE=${HM_KNOWN_LIST_MODE:-"guest"}

# MAC/IP addresses of other known devices (all others will be
# recognized as guest devices
HM_KNOWN_LIST=${HM_KNOWN_LIST:-""}

# number of seconds to wait between iterations
# (will run hm_pdetect in an endless loop)
HM_INTERVAL_TIME=${HM_INTERVAL_TIME:-}

# maximum number of iterations if running in interval mode
# (default: 0=unlimited)
HM_INTERVAL_MAX=${HM_INTERVAL_MAX:-0}

# where to save the process ID in case hm_pdetect runs as
# a daemon
HM_DAEMON_PIDFILE=${HM_DAEMON_PIDFILE:-"/var/run/hm_pdetect.pid"}

# Processing logfile output name
# (default: no output)
HM_PROCESSLOG_FILE=${HM_PROCESSLOG_FILE:-}

# maximum number of lines the logfile should contain
# (default: 500 lines)
HM_PROCESSLOG_MAXLINES=${HM_PROCESSLOG_MAXLINES:-500}

# the config file path
# (default: 'hm_pdetect.conf' in path where hm_pdetect.sh script resists)
CONFIG_FILE=${CONFIG_FILE:-"$(cd "${0%/*}"; pwd)/hm_pdetect.conf"}

# global return status variables
RETURN_FAILURE=1
RETURN_SUCCESS=0

###############################
# now we check all dependencies first. That means we
# check that we have the right bash version and third-party tools
# installed
#

# bash check
if [[ $(echo ${BASH_VERSION} | cut -d. -f1) -lt 4 ]]; then
  echo "ERROR: this script requires a bash shell of version 4 or higher. Please install."
  exit ${RETURN_FAILURE}
fi

# wget check
if [[ ! -x $(which wget) ]]; then
  echo "ERROR: 'wget' tool missing. Please install."
  exit ${RETURN_FAILURE}
fi

# iconv check
if [[ ! -x $(which iconv) ]]; then
  echo "ERROR: 'iconv' tool missing. Please install."
  exit ${RETURN_FAILURE}
fi

# md5sum check
if [[ ! -x $(which md5sum) ]]; then
  echo "ERROR: 'md5sum' tool missing. Please install."
  exit ${RETURN_FAILURE}
fi

# declare all associative arrays first (bash v4+ required)
declare -A HM_USER_LIST     # username<>MAC/IP tuple
declare -A normalDeviceList # MAC<>IP tuple (normal-WiFi/LAN)
declare -A guestDeviceList  # MAC<>IP tuple (guest-WiFi/LAN)
declare -A sidStorage       # IP<>SID tuple

###############################
# lets check if config file was specified as a cmdline arg
if [[ ${#} -gt 0        && \
      ${!#} != "child"  && \
      ${!#} != "daemon" && \
      ${!#} != "start"  && \
      ${!#} != "stop" ]]; then
  CONFIG_FILE="${!#}"
fi

if [[ ! -e ${CONFIG_FILE} ]]; then
  echo "WARNING: config file '${CONFIG_FILE}' doesn't exist. Using default values."
  CONFIG_FILE=
fi

# lets source the config file a first time
if [[ -n ${CONFIG_FILE} ]]; then
  source "${CONFIG_FILE}"
  if [[ $? -ne 0 ]]; then
    echo "ERROR: couldn't source config file '${CONFIG_FILE}'. Please check config file syntax."
    exit ${RETURN_FAILURE}
  fi

  # lets eval the user overridden variables
  # so that they take priority
  eval ${USERVARS}
fi

###############################
# run hm_pdetect as a real daemon by using setsid
# to fork and deattach it from a terminal.
PROCESS_MODE=normal
if [[ ${#} -gt 0 ]]; then
  FILE=${0##*/}
  DIR=$(cd "${0%/*}"; pwd)

  # lets check the supplied command
  case "${1}" in

    start) # 1. lets start the child
      shift
      exec "${DIR}/${FILE}" child "${CONFIG_FILE}" &
      exit 0
    ;;

    child) # 2. We are the child. We need to fork the daemon now
      shift
      umask 0
      echo
      echo "Starting hm_pdetect in daemon mode."
      exec setsid ${DIR}/${FILE} daemon "${CONFIG_FILE}" </dev/null >/dev/null 2>/dev/null &
      exit 0
    ;;

    daemon) # 3. We are the daemon. Lets continue with the real stuff
      shift
      # save the PID number in the specified PIDFILE so that we 
      # can kill it later on using this file
      if [[ -n ${HM_DAEMON_PIDFILE} ]]; then
        echo $$ >${HM_DAEMON_PIDFILE}
      fi

      # if we end up here we are in daemon mode and
      # can continue normally but make sure we don't allow any
      # input
      exec 0</dev/null

      # make sure PROCESS_MODE is set to daemon
      PROCESS_MODE=daemon
    ;;

    stop) # 4. stop the daemon if requested
      if [[ -f ${HM_DAEMON_PIDFILE} ]]; then
        echo "Stopping hm_pdetect (pid: $(cat ${HM_DAEMON_PIDFILE}))"
        kill $(cat ${HM_DAEMON_PIDFILE}) >/dev/null 2>&1
        rm -f ${HM_DAEMON_PIDFILE} >/dev/null 2>&1
      fi
      exit 0
    ;;

  esac
fi
 
###############################
# function returning the current state of a homematic variable
# and returning success/failure if the variable was found/not
function getVariableState()
{
  local name="$1"

  local result=$(wget -q -O - "http://${HM_CCU_IP}:8181/rega.exe?state=dom.GetObject(ID_SYSTEM_VARIABLES).Get('${name}').Value()")
  if [[ ${result} =~ \<state\>(.*)\</state\> ]]; then
    result="${BASH_REMATCH[1]}"
    if [[ ${result} != "null" ]]; then
      echo ${result}
      return ${RETURN_SUCCESS}
    fi
  fi

  echo ${result}
  return ${RETURN_FAILURE}
}

# function setting the state of a homematic variable in case it
# it different to the current state and the variable exists
function setVariableState()
{
  local name="$1"
  local newstate="$2"

  # before we going to set the variable state we
  # query the current state and if the variable exists or not
  curstate=$(getVariableState "${name}")
  if [[ ${curstate} == "null" ]]; then
    return ${RETURN_FAILURE}
  fi

  # only continue if the current state is different to the new state
  if [[ ${curstate} == ${newstate//\'} ]]; then
    return ${RETURN_SUCCESS}
  fi

  # the variable should be set to a new state, so lets do it
  echo -n "  Setting CCU variable '${name}': '${newstate//\'}'... "
  local result=$(wget -q -O - "http://${HM_CCU_IP}:8181/rega.exe?state=dom.GetObject(ID_SYSTEM_VARIABLES).Get('${name}').State(${newstate})")
  if [[ ${result} =~ \<state\>(.*)\</state\> ]]; then
    result="${BASH_REMATCH[1]}"
  else
    result=""
  fi

  # if setting the variable succeeded the result will be always
  # 'true'
  if [[ ${result} == "true" ]]; then
    echo "ok."
    return ${RETURN_SUCCESS}
  fi

  echo "ERROR."
  return ${RETURN_FAILURE}
}

# function to check if a certain boolean system variable exists
# at a CCU and if not creates it accordingly
function createVariable()
{
  local vaname=$1
  local vatype=$2
  local comment=$3
  local valist=$4

  # first we find out if the variable already exists and if
  # the value name/list it contains matches the value name/list
  # we are expecting
  local postbody=""
  if [[ ${vatype} == "enum" ]]; then
    local result=$(wget -q -O - "http://${HM_CCU_IP}:8181/rega.exe?valueList=dom.GetObject(ID_SYSTEM_VARIABLES).Get('${vaname}').ValueList()")
    if [[ ${result} =~ \<valueList\>(.*)\</valueList\> ]]; then
      result="${BASH_REMATCH[1]}"
    fi

    # make sure result is not empty and not null
    if [[ -n ${result} && ${result} != "null" ]]; then
      if [[ ${result} != ${valist} ]]; then
        echo -n "  Modifying CCU variable '${vaname}' (${vatype})... "
        postbody="string v='${vaname}';dom.GetObject(ID_SYSTEM_VARIABLES).Get(v).ValueList('${valist}')"
      fi
    else
      echo -n "  Creating CCU variable '${vaname}' (${vatype})... "
      postbody="string v='${vaname}';boolean f=true;string i;foreach(i,dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs()){if(v==dom.GetObject(i).Name()){f=false;}};if(f){object s=dom.GetObject(ID_SYSTEM_VARIABLES);object n=dom.CreateObject(OT_VARDP);n.Name(v);s.Add(n.ID());n.ValueType(ivtInteger);n.ValueSubType(istEnum);n.DPInfo('${comment}');n.ValueList('${valist}');n.State(0);dom.RTUpdate(false);}"
    fi
  elif [[ ${vatype} == "string" ]]; then
    getVariableState "${vaname}" >/dev/null
    if [[ $? -eq 1 ]]; then
      echo -n "  Creating CCU variable '${vaname}' (${vatype})... "
      postbody="string v='${vaname}';boolean f=true;string i;foreach(i,dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs()){if(v==dom.GetObject(i).Name()){f=false;}};if(f){object s=dom.GetObject(ID_SYSTEM_VARIABLES);object n=dom.CreateObject(OT_VARDP);n.Name(v);s.Add(n.ID());n.ValueType(ivtString);n.ValueSubType(istChar8859);n.DPInfo('${comment}');n.State('');dom.RTUpdate(false);}"
    fi
  else
    local result=$(wget -q -O - "http://${HM_CCU_IP}:8181/rega.exe?valueName0=dom.GetObject(ID_SYSTEM_VARIABLES).Get('${vaname}').ValueName0()&valueName1=dom.GetObject(ID_SYSTEM_VARIABLES).Get('${vaname}').ValueName1()")
    local valueName0="null"
    local valueName1="null"
    if [[ ${result} =~ \<valueName0\>(.*)\</valueName0\>\<valueName1\>(.*)\</valueName1\> ]]; then
      valueName0="${BASH_REMATCH[1]}"
      valueName1="${BASH_REMATCH[2]}"
    fi

    # make sure result is not empty and not null
    if [[ -n ${result} && \
          ${valueName0} != "null" && ${valueName1} != "null" ]]; then

       if [[ ${valueName0} != ${HM_CCU_PRESENCE_AWAY} || \
             ${valueName1} != ${HM_CCU_PRESENCE_PRESENT} ]]; then
         echo -n "  Modifying CCU variable '${vaname}' (${vatype})... "
         postbody="string v='${vaname}';dom.GetObject(ID_SYSTEM_VARIABLES).Get(v).ValueName0('${HM_CCU_PRESENCE_AWAY}');dom.GetObject(ID_SYSTEM_VARIABLES).Get(v).ValueName1('${HM_CCU_PRESENCE_PRESENT}')"
       fi
    else
      echo -n "  Creating CCU variable '${vaname}' (${vatype})... "
      postbody="string v='${vaname}';boolean f=true;string i;foreach(i,dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs()){if(v==dom.GetObject(i).Name()){f=false;}};if(f){object s=dom.GetObject(ID_SYSTEM_VARIABLES);object n=dom.CreateObject(OT_VARDP);n.Name(v);s.Add(n.ID());n.ValueType(ivtBinary);n.ValueSubType(istBool);n.DPInfo('${comment}');n.ValueName1('${HM_CCU_PRESENCE_PRESENT}');n.ValueName0('${HM_CCU_PRESENCE_AWAY}');n.State(false);dom.RTUpdate(false);}"
    fi
  fi

  # if postbody is empty there is nothing to do
  # and the variable exists with correct value name/list
  if [[ -z ${postbody} ]]; then
    return ${RETURN_SUCCESS}
  fi

  # use wget to post the tcl script to tclrega.exe
  local result=$(wget -q -O - --post-data "${postbody}" "http://${HM_CCU_IP}:8181/tclrega.exe")
  if [[ ${result} =~ \<v\>${vaname}\</v\> ]]; then
    echo "ok."
    return ${RETURN_SUCCESS}
  else
    echo "ERROR: could not create system variable '${vaname}'."
    return ${RETURN_FAILURE}
  fi
}

# function that logs into a LANCOM! device and stores the MAC and IP address of all devices
# in an associative array which have to bre created before calling this function
function retrieveLancomDeviceList()
{
  local ip=$1
  local user=$2
  local secret=$3




  # retrieve the network device list from the lancombox using snmp call
  local devices_mac=
  local devices_ip=
  local res=1


  devices_mac=$(snmpwalk -v3 -l authPriv -u ${user} -a SHA -A ${secret} -x AES -X ${secret} ${ip} 1.3.6.1.4.1.2356.11.1.3.32.1.4)
  devices_ip=$(snmpwalk -v3 -l authPriv -u ${user} -a SHA -A ${secret} -x AES -X ${secret} ${ip} 1.3.6.1.4.1.2356.11.1.3.32.1.27)
  devices_status=$(snmpwalk -v3 -l authPriv -u ${user} -a SHA -A ${secret} -x AES -X ${secret} ${ip} 1.3.6.1.4.1.2356.11.1.3.32.1.10)
  devices_network=$(snmpwalk -v3 -l authPriv -u ${user} -a SHA -A ${secret} -x AES -X ${secret} ${ip} 1.3.6.1.4.1.2356.11.1.3.32.1.25)
  res=$?

  # perform a last check
  if [[ ${res} -ne 0 || -z ${devices_mac} || -z ${devices_ip} || -z ${devices_status} || -z ${devices_network} ]]; then
    echo
    echo "ERROR: Couldn't retrieve device list."
    return ${RETURN_FAILURE}
  fi

  devices_mac=${devices_mac//[[:space:]]SNMP/$'\n'SNMP}
  devices_ip=${devices_ip//[[:space:]]SNMP/$'\n'SNMP}
  devices_status=${devices_status//[[:space:]]SNMP/$'\n'SNMP}
  devices_network=${devices_network//[[:space:]]SNMP/$'\n'SNMP}

  # prepare the regular expressions
  local re_mac=".*Hex-STRING:[[:space:]](.*)"
  local re_ip=".*IpAddress:[[:space:]](.*)"
  local re_status=".*INTEGER:[[:space:]](.*)"
  local re_network=".*INTEGER:[[:space:]](.*)"

  local maclist=()
  local iplist=()
  local statuslist=()
  local networklist=()


  while read -r line; do
    if [[ $line =~ $re_mac ]]; then
      mac="${BASH_REMATCH[1]//[[:space:]]/:}"
    fi
    maclist+=(${mac^^})
    mac=""
  done <<< "${devices_mac}"

  while read -r line; do
    if [[ $line =~ $re_ip ]]; then
      ipaddr="${BASH_REMATCH[1]}"
    fi
    iplist+=(${ipaddr})
    ipaddr=""
  done <<< "${devices_ip}"

  while read -r line; do
    if [[ $line =~ $re_status ]]; then
      status="${BASH_REMATCH[1]}"
    fi
    statuslist+=(${status})
    status=""
  done <<< "${devices_status}"

  while read -r line; do
    if [[ $line =~ $re_network ]]; then
      network="${BASH_REMATCH[1]}"
    fi
    networklist+=(${network})
    network=""
  done <<< "${devices_network}"


  for (( i = 0; i < ${#maclist[@]} ; i++ )); do
    if [[ ${statuslist[$i]} -eq 3 ]]; then
      if [[ ${networklist[$i]} -eq 0 ]]; then
        normalDeviceList[${maclist[$i]}]=${iplist[$i]}
      elif [[ ${networklist[$i]} -eq 1 ]]; then
        guestDeviceList[${maclist[$i]}]=${iplist[$i]}
      fi
    fi
  done

  return ${RETURN_SUCCESS}
}

# function that creates a list of tupels from an input string
# of individual users. This tuple list can then be used to be set for the
# presence.list variable type when constructing it
function createUserTupleList()
{
  local a="$1"

  # constract the brace expansion string from the input
  # string so that we end up with something like '{1,}{2,}{3,}', etc.
  local b=""
  local i=0
  IFS=';'
  for Y in ${a}; do
    ((i = i + 1))
    b=$b{$i,}
  done
  IFS=' '

  # lets apply the brace expansion string and sort it
  # according to numbers and not have it in the standard sorting
  local c=$(for X in $(eval echo\ $b); do echo $X; done | sort -n | tr '\n' ' ')

  # lets construct tupels for every number (1-9) in
  # the brace expansion
  local tuples=""
  for X in ${c}; do
    if [[ -n ${tuples} ]]; then
      tuples="${tuples};"
    fi
    folded=$(echo -n ${X} | fold -w1 | tr '\n' ',')
    tuples="${tuples}${folded}"
  done

  # now we replace each number (1-9) with the appropriate
  # string of the input array
  local i=0
  IFS=';'
  for Z in ${a}; do
    ((i = i + 1))
    tuples=${tuples//${i}/${Z}}
  done
  IFS=' '

  # now add "Guest" to each tuple (if not disabled)
  local guestTuples=""
  if [[ -n ${HM_CCU_PRESENCE_GUEST} && \
        ${HM_KNOWN_LIST_MODE} != "off" && \
        ${HM_CCU_PRESENCE_GUEST_ENABLED} == true ]]; then
    IFS=';'
    guestTuples=";${HM_CCU_PRESENCE_GUEST}"
    for U in ${tuples}; do
      guestTuples="${guestTuples};${U},${HM_CCU_PRESENCE_GUEST}"
    done
    IFS=' '
  fi

  tuples="${HM_CCU_PRESENCE_NOBODY};${tuples}${guestTuples}"

  echo "${tuples}"
}

# function to count the position within the enum list
# where the presence list matches
function whichEnumID()
{
  local enumList="$1"
  local presenceList="$2"

  # now we iterate through the ;—separated enumList
  IFS=';'
  local i=0
  local result=0
  for id in ${enumList}; do
    if [[ ${presenceList} == ${id} ]]; then
      result=$i
      break
    fi
    ((i = i + 1 ))
  done
  IFS=' '

  echo ${result}
}

function run_pdetect()
{
  # output time/date of execution
  echo "== $(date) ==================================="

  # lets retrieve all mac<>ip addresses of currently
  # active devices in our network
  echo -n "Querying LANCOM devices:"
  i=0
  for ip in ${HM_LANCOM_IP[@]}; do
    echo -n " ${ip}"
    retrieveLancomDeviceList ${ip} "${HM_LANCOM_USER}" "${HM_LANCOM_SECRET}"
    if [[ $? -eq 0 ]]; then
      ((i = i + 1))
    fi
  done
  
  # check that we were able to connect to at least one device
  if [[ ${i} -eq 0 ]]; then
    echo "ERROR: couldn't connect to any specified LANCOM device."
    return ${RETURN_FAILURE}
  fi

  # output some statistics
  echo
  echo " Normal-WiFi/LAN devices active: ${#normalDeviceList[@]}"
  echo " Guest-WiFi/LAN devices active: ${#guestDeviceList[@]}"
  
  # lets identify user presence
  presenceList=""
  echo "Checking user presence: "
  for user in "${!HM_USER_LIST[@]}"; do
    echo -n " ${user}: "
    stat="false"
  
    # prepare the device list of the user as a regex
    userDeviceList=$(echo ${HM_USER_LIST[${user}]} | tr ' ' '|')

    # match MAC address and IP address in normal and guest WiFi/LAN
    if [[ ${normalDeviceList[@]}  =~ ${userDeviceList^^} || \
          ${guestDeviceList[@]}   =~ ${userDeviceList^^} || \
          ${!normalDeviceList[@]} =~ ${userDeviceList^^} || \
          ${!guestDeviceList[@]}  =~ ${userDeviceList^^} ]]; then
      stat="true"
    fi
  
    if [[ ${stat} == "true" ]]; then
      echo present
      if [[ -n ${presenceList} ]]; then
        presenceList+=","
      fi
      presenceList+="${user}"
    else
      echo away
    fi
  
    # remove checked user devices from deviceList so that
    # they are not recognized as guest devices
    for device in ${HM_USER_LIST[${user}]}; do
      # try to match MAC address first
      if [[ ${!normalDeviceList[@]} =~ ${device^^} ]]; then
        unset normalDeviceList[${device^^}]
      elif [[ ${!guestDeviceList[@]} =~ ${device^^} ]]; then
        unset guestDeviceList[${device^^}]
      else
        # now match the IP address list instead
        if [[ ${normalDeviceList[@]} =~ ${device^^} ]]; then
          for dev in ${!normalDeviceList[@]}; do
            if [[ ${normalDeviceList[${dev}]} == ${device^^} ]]; then
              unset normalDeviceList[${dev}]
              break
            fi
          done
        elif [[ ${guestDeviceList[@]} =~ ${device^^} ]]; then
          for dev in ${!guestDeviceList[@]}; do
            if [[ ${guestDeviceList[${dev}]} == ${device^^} ]]; then
              unset guestDeviceList[${dev}]
              break
            fi
          done
        fi
      fi
    done
  
    # set status in homematic CCU
    createVariable "${HM_CCU_PRESENCE_VAR}.${user}" bool "${user} @ home"
    setVariableState "${HM_CCU_PRESENCE_VAR}.${user}" ${stat}
  done
  
  # now we set a separate users presence variable to true/false in case
  # any defined user is present
  if [[ -n ${HM_CCU_PRESENCE_USER} && ${HM_CCU_PRESENCE_USER_ENABLED} == true ]]; then
    createVariable "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_USER}" bool "any user @ home"
    if [[ -n ${presenceList} ]]; then
      setVariableState "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_USER}" true
    else
      setVariableState "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_USER}" false
    fi
  fi
  
  # lets identify guests by checking the normal and guest
  # WiFi/LAN device list and comparing them to the HM_KNOWN_LIST
  HM_KNOWN_LIST=( ${HM_KNOWN_LIST[@]^^} ) # uppercase array
  for device in ${HM_KNOWN_LIST[@]}; do
  
    # try to match MAC address first
    if [[ ${!normalDeviceList[@]} =~ ${device} ]]; then
      unset normalDeviceList[${device}]
    elif [[ ${!guestDeviceList[@]} =~ ${device} ]]; then
      unset guestDeviceList[${device}]
    else
      # now match the IP address list instead
      if [[ ${normalDeviceList[@]} =~ ${device} ]]; then
        for dev in ${!normalDeviceList[@]}; do
          if [[ ${normalDeviceList[${dev}]} == ${device} ]]; then
            unset normalDeviceList[${dev}]
            break
          fi
        done
      elif [[ ${guestDeviceList[@]} =~ ${device} ]]; then
        for dev in ${!guestDeviceList[@]}; do
          if [[ ${guestDeviceList[${dev}]} == ${device} ]]; then
            unset guestDeviceList[${dev}]
            break
          fi
        done
      fi
    fi
  
  done
  
  # depending on the HM_KNOWN_LIST_MODE mode we populate the guestList
  # with devices from the normalDeviceList and guestDeviceList or
  # just from the guestDeviceList
  guestList=()
  if [[ ${HM_KNOWN_LIST_MODE} != "guest" ]]; then
    for device in ${!normalDeviceList[@]}; do
      guestList+=(${device})
    done
  fi
  for device in ${!guestDeviceList[@]}; do
    guestList+=(${device})
  done
  
  echo "Checking guest presence: "
  # create/set presence system variable in CCU if guest devices
  # were found
  echo -n " ${HM_CCU_PRESENCE_GUEST}: "
  if [[ ${HM_KNOWN_LIST_MODE} != "off" ]]; then
    if [[ ${#guestList[@]} -gt 0 ]]; then
      # set status in homematic CCU
      echo "present - ${#guestList[@]} (${guestList[@]})"
      createVariable "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_GUEST}" bool "${HM_CCU_PRESENCE_GUEST} @ home"
      setVariableState "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_GUEST}" true
      if [[ -n ${presenceList} ]]; then
        presenceList+=","
      fi
      presenceList+="${HM_CCU_PRESENCE_GUEST}"
    else
      echo "away"
      createVariable "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_GUEST}" bool "${HM_CCU_PRESENCE_GUEST} @ home"
      setVariableState "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_GUEST}" false
    fi
  else
    echo "disabled"
  fi
  
  # we create and set another global presence variable as an
  # enum of all possible presence combinations
  if [[ -n ${HM_CCU_PRESENCE_LIST} && ${HM_CCU_PRESENCE_LIST_ENABLED} == true ]]; then
    userList=""
    for user in "${!HM_USER_LIST[@]}"; do
      if [[ -n ${userList} ]]; then
        userList="${userList};${user}"
      else
        userList="${user}"
      fi
    done
    userTupleList=$(createUserTupleList "${userList}")
    createVariable "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_LIST}" enum "presence enum list @ home" "${userTupleList}"
    setVariableState "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_LIST}" $(whichEnumID "${userTupleList}" "${presenceList}")
  fi
  
  # we create and set a global presence variable as a string
  # variable which users can query.
  if [[ -n ${HM_CCU_PRESENCE_STR} && ${HM_CCU_PRESENCE_STR_ENABLED} == true ]]; then
    if [[ -z ${presenceList} ]]; then
      userList="${HM_CCU_PRESENCE_NOBODY}"
    else
      userList="${presenceList}"
    fi
    createVariable "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_STR}" string "presence list @ home"
    setVariableState "${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_STR}" "'${userList}'"
  fi
  
  # set the global presence variable to true/false depending
  # on the general presence of people in the house
  createVariable "${HM_CCU_PRESENCE_VAR}" bool "global presence @ home"
  if [[ -z ${presenceList} ]]; then
    setVariableState "${HM_CCU_PRESENCE_VAR}" false
  else
    setVariableState "${HM_CCU_PRESENCE_VAR}" true
  fi
  
  echo "== $(date) ==================================="
  echo
  
  return ${RETURN_SUCCESS}
}

################################################
# main processing starts here
#
echo "hm_pdetect ${VERSION} - a LANCOM!-based HomeMatic presence detection script"
echo "(${VERSION_DATE}) Copyright (C) 2015-2017 Jens Maus <mail@jens-maus.de>"
echo

# lets enter an endless loop to implement a
# daemon-like behaviour
result=-1
iteration=0
while true; do

  # lets source the config file again
  if [[ -n ${CONFIG_FILE} ]]; then
    source "${CONFIG_FILE}"
    if [[ $? -ne 0 ]]; then
      echo "ERROR: couldn't source config file '${CONFIG_FILE}'. Please check config file syntax."
      result=${RETURN_FAILURE}
    fi

    # lets eval the user overridden variables
    # so that they take priority
    eval ${USERVARS}
  fi

  # lets wait until the next execution round in case
  # the user wants to run it as a daemon
  if [[ ${result} -ge 0 ]]; then
    ((iteration = iteration + 1))
    if [[ -n ${HM_INTERVAL_TIME}    && \
          ${HM_INTERVAL_TIME} -gt 0 && \
          ( -z ${HM_INTERVAL_MAX} || ${HM_INTERVAL_MAX} -eq 0 || ${iteration} -lt ${HM_INTERVAL_MAX} ) ]]; then
      sleep ${HM_INTERVAL_TIME}
      if [[ $? -eq 1 ]]; then
        result=${RETURN_FAILURE}
        break
      fi
    else 
      break
    fi
  fi

  # perform one pdetect run and in case we are running in daemon
  # mode and having the processlogfile enabled output to the logfile instead.
  if [[ -n ${HM_PROCESSLOG_FILE} ]]; then
    output=$(run_pdetect)
    result=$?
    echo "${output}" | cat - ${HM_PROCESSLOG_FILE} | head -n ${HM_PROCESSLOG_MAXLINES} >/tmp/hm_pdetect-$$.tmp && mv /tmp/hm_pdetect-$$.tmp ${HM_PROCESSLOG_FILE}
  else
    # run pdetect with normal stdout processing
    run_pdetect
    result=$?
  fi

done

exit ${result}
