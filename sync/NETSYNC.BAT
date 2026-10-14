@ECHO OFF
REM NETSYNC - fetch the files that changed on the server (needs mTCP HTGET)
REM   SET SYNCSRV=192.168.1.10:8080   server and port of netsync.py
REM   SET SYNCDST=C:\                 target directory, with trailing backslash
REM   SET SYNCSTATE=C:\NSGEN.BAT      where the last generation is stored
IF "%SYNCSRV%"=="" GOTO NOSRV
IF "%SYNCDST%"=="" SET SYNCDST=C:\
IF "%SYNCSTATE%"=="" SET SYNCSTATE=C:\NSGEN.BAT
SET SYNCGEN=0
IF EXIST %SYNCSTATE% CALL %SYNCSTATE%
HTGET -o %SYNCDST%NSRUN.BAT http://%SYNCSRV%/sync.bat?since=%SYNCGEN%
IF ERRORLEVEL 1 GOTO NOCONN
CALL %SYNCDST%NSRUN.BAT
DEL %SYNCDST%NSRUN.BAT
GOTO END
:NOSRV
ECHO NETSYNC: SET SYNCSRV=server:port first
GOTO END
:NOCONN
ECHO NETSYNC: server %SYNCSRV% not reachable
:END
SET SYNCGEN=
