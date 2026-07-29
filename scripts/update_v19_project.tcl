set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_xpr [file join $project_root EO_Panorama_V19_M1.xpr]

# Fileset logic lives in v19_fileset.tcl so the synth/impl entry points can
# re-assert it too -- Vivado batch runs have been seen dropping source entries
# from the .xpr on close_project.
source [file join $project_root scripts v19_fileset.tcl]

open_project $project_xpr
v19_refresh_fileset $project_root
close_project
