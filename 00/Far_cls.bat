@Echo Off

call C:\MSVCE\VC\bin\vcvars32.bat

cd unicode_far
nmake.exe /f makefile_vc clean
nmake.exe /f makefile_vc DEBUG=1 clean
cd ..


cd plugins\arclite
nmake.exe /f makefile_vc clean
nmake.exe /f makefile_vc DEBUG=1 clean
cd ..\..


cd plugins
rem nmake.exe /f makefile_all_vc %* || exit

FOR /R %%F IN (makefile_vc*.) DO (

  if exist "%%~dpF%final.32W.vc" (
    echo rd %%~dpF%final.32W.vc
    rd /S /Q "%%~dpF%final.32W.vc"
  )

  if exist "%%~dpF%final.32.vc" (
    echo rd %%~dpF%final.32.vc
    rd /S /Q "%%~dpF%final.32.vc"
  )

)

del plugins.sdf
del common\*.lib common\*.a
del helloworld\*.dll helloworld\*.map helloworld\*.o
del newarc\src\*.dll.base
rd /S /Q common\CRT\obj.32.vc
rd /S /Q common\CRT\obj.32.gcc
rd /S /Q NewArc\O


cd ..


