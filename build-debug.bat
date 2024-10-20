mkdir bin\debug
odin build . -strict-style -debug -collection:sm=Spelmotor/engine/src -out:bin/debug/Jumper.exe -target:windows_amd64 -o:none -show-timings -show-system-calls