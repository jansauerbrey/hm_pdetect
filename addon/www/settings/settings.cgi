#!/usr/bin/env tclsh
source [file join [file dirname [info script]] inc/settings.tcl]

parseQuery

if { $args(command) == "defaults" } {
  set args(HM_LANCOM_IP) ""
  set args(HM_LANCOM_USER) ""
  set args(HM_LANCOM_SECRET) ""
  set args(HM_CCU_PRESENCE_VAR) ""
  set args(HM_CCU_PRESENCE_LIST) ""
  set args(HM_CCU_PRESENCE_LIST_ENABLED) ""
  set args(HM_CCU_PRESENCE_STR) ""
  set args(HM_CCU_PRESENCE_STR_ENABLED) ""
  set args(HM_CCU_PRESENCE_GUEST) ""
  set args(HM_CCU_PRESENCE_GUEST_ENABLED) ""
  set args(HM_CCU_PRESENCE_NOBODY) ""
  set args(HM_CCU_PRESENCE_USER) ""
  set args(HM_CCU_PRESENCE_USER_ENABLED) ""
  set args(HM_CCU_PRESENCE_PRESENT) ""
  set args(HM_CCU_PRESENCE_AWAY) ""
  set args(HM_USER_LIST) ""
  set args(HM_KNOWN_LIST_MODE) ""
  set args(HM_KNOWN_LIST) ""
  set args(HM_INTERVAL_TIME) ""
  
  # force save of data
  set args(command) "save"
} 

if { $args(command) == "save" } {
	saveConfigFile
} 

set HM_LANCOM_IP ""
set HM_LANCOM_USER ""
set HM_LANCOM_SECRET ""
set HM_CCU_PRESENCE_VAR ""
set HM_CCU_PRESENCE_LIST ""
set HM_CCU_PRESENCE_LIST_ENABLED ""
set HM_CCU_PRESENCE_STR ""
set HM_CCU_PRESENCE_STR_ENABLED ""
set HM_CCU_PRESENCE_GUEST ""
set HM_CCU_PRESENCE_GUEST_ENABLED ""
set HM_CCU_PRESENCE_NOBODY ""
set HM_CCU_PRESENCE_USER ""
set HM_CCU_PRESENCE_USER_ENABLED ""
set HM_CCU_PRESENCE_PRESENT ""
set HM_CCU_PRESENCE_AWAY ""
set HM_USER_LIST ""
set HM_KNOWN_LIST_MODE ""
set HM_KNOWN_LIST ""
set HM_INTERVAL_TIME ""

loadConfigFile
set content [loadFile settings.html]
source [file join [file dirname [info script]] inc/settings1.tcl]
