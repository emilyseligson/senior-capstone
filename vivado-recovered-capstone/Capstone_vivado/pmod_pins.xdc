## Pmod pin constraints for eis_core on the PYNQ-Z2
## Check each PACKAGE_PIN against the PYNQ-Z2 master XDC (ja[0] = JA pin 1, etc.)
## and the pin order against the Digilent Pmod DA2 / AD1 reference manuals.
## Port names must match the external ports in the block design
## (Make External adds a "_0" suffix; rename the ports or edit the names here).

## Pmod DA2 on header JA, top row (pins 1-4)
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports da2_sync]   ;# JA1
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports da2_dina]   ;# JA2
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports da2_dinb]   ;# JA3
set_property -dict { PACKAGE_PIN Y17 IOSTANDARD LVCMOS33 } [get_ports da2_sclk]   ;# JA4

## Pmod AD1 on header JB, top row (pins 1-4)
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports ad1_cs]     ;# JB1
set_property -dict { PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 } [get_ports ad1_d0]     ;# JB2
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports ad1_d1]     ;# JB3
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports ad1_sclk]   ;# JB4
