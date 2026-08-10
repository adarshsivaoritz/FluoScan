@echo off
REM Change FluoScan below if your GitHub repository has a different name.
flutter pub get
flutter build web --release --base-href /FluoScan/
echo.
echo Build complete in build\web
pause
