

set GWSH=C:\Gowin\Gowin_V1.9.9_x64\IDE\bin\gw_sh

@REM echo
@REM echo "============ Building mega60k with snes controller ==============="
@REM echo
@REM %GWSH% build.tcl mega60k snes

@REM echo
@REM echo "============ Building mega60k with ds2 controller ==============="
@REM echo
@REM %GWSH% build.tcl mega60k ds2

echo
echo "============ Building nano20k ==============="
echo
%GWSH% build.tcl nano20k

@REM echo
@REM echo "============ Building primer25k with snes controller ==============="
@REM echo
@REM %GWSH% build.tcl primer25k snes

@REM echo
@REM echo "============ Building primer25k with ds2 controller ==============="
@REM echo
@REM %GWSH% build.tcl primer25k ds2

@REM echo
@REM echo "============ Building mega138k pro with snes controller ==============="
@REM echo
@REM %GWSH% build.tcl mega138k snes

@REM echo
@REM echo "============ Building mega138k pro with ds2 controller ==============="
@REM echo
@REM %GWSH% build.tcl mega138k ds2

dir impl\pnr\*.fs

echo "All done."

