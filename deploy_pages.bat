@echo off
REM FluoScan v0.4 GitHub Pages release build.
call flutter pub get
if errorlevel 1 exit /b %errorlevel%
call flutter build web --release --base-href /FluoScan/
if errorlevel 1 exit /b %errorlevel%
echo.
echo Build complete in build\web
pause
