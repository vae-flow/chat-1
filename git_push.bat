@echo off
chcp 65001 >nul
echo === Git Push Script ===
echo.
echo Adding files...
git add .
echo.
echo Status:
git status --short
echo.
echo Committing...
git commit -m "fix: revive all dead code - activate unused imports, variables, methods and constants"
echo.
echo Pushing to origin main...
git push origin main
echo.
echo Done!
pause
