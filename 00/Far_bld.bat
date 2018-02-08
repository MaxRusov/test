@Echo Off

call C:\MSVC\VC\bin\vcvars32.bat

cd unicode_far
nmake.exe /f makefile_vc %* || exit
cd ..

cd plugins
nmake.exe /f makefile_all_vc %* || exit
cd ..

rem cd plugins\arclite
rem nmake.exe /f makefile_vc %* || exit
rem cd ..\..

rem cd plugins\luamacro
rem nmake.exe /f makefile_vc %* || exit
rem cd ..\..
