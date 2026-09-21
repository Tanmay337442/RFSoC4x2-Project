# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "CFG_LAUNCH_DELAY" -parent ${Page_0}
  ipgui::add_param $IPINST -name "CFG_MIN_COMMIT_GAP_CYCLES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXIS_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "SEGMENTS" -parent ${Page_0}


}

proc update_PARAM_VALUE.CFG_LAUNCH_DELAY { PARAM_VALUE.CFG_LAUNCH_DELAY } {
	# Procedure called to update CFG_LAUNCH_DELAY when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CFG_LAUNCH_DELAY { PARAM_VALUE.CFG_LAUNCH_DELAY } {
	# Procedure called to validate CFG_LAUNCH_DELAY
	return true
}

proc update_PARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES { PARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES } {
	# Procedure called to update CFG_MIN_COMMIT_GAP_CYCLES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES { PARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES } {
	# Procedure called to validate CFG_MIN_COMMIT_GAP_CYCLES
	return true
}

proc update_PARAM_VALUE.C_S_AXIS_DATA_WIDTH { PARAM_VALUE.C_S_AXIS_DATA_WIDTH } {
	# Procedure called to update C_S_AXIS_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXIS_DATA_WIDTH { PARAM_VALUE.C_S_AXIS_DATA_WIDTH } {
	# Procedure called to validate C_S_AXIS_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to update C_S_AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to validate C_S_AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.SEGMENTS { PARAM_VALUE.SEGMENTS } {
	# Procedure called to update SEGMENTS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.SEGMENTS { PARAM_VALUE.SEGMENTS } {
	# Procedure called to validate SEGMENTS
	return true
}


proc update_MODELPARAM_VALUE.C_S_AXIS_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXIS_DATA_WIDTH PARAM_VALUE.C_S_AXIS_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXIS_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXIS_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.SEGMENTS { MODELPARAM_VALUE.SEGMENTS PARAM_VALUE.SEGMENTS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.SEGMENTS}] ${MODELPARAM_VALUE.SEGMENTS}
}

proc update_MODELPARAM_VALUE.CFG_LAUNCH_DELAY { MODELPARAM_VALUE.CFG_LAUNCH_DELAY PARAM_VALUE.CFG_LAUNCH_DELAY } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CFG_LAUNCH_DELAY}] ${MODELPARAM_VALUE.CFG_LAUNCH_DELAY}
}

proc update_MODELPARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES { MODELPARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES PARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES}] ${MODELPARAM_VALUE.CFG_MIN_COMMIT_GAP_CYCLES}
}

