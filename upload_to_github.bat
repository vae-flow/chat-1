@echo off
chcp 65001 >nul
echo ==========================================
echo       One-API 客户端 - 自动上传脚本
echo ==========================================
echo.

WHERE git >nul 2>nul
IF %ERRORLEVEL% NEQ 0 (
    echo [错误] 未检测到 Git！
    echo 请先下载并安装 Git：https://git-scm.com/download/win
    echo 安装后请重新运行此脚本。
    echo.
    pause
    exit /b
)

echo 请输入你在 GitHub 上创建的仓库地址
echo (格式如: https://github.com/yourname/repo.git)
set /p REPO_URL="仓库地址: "

if "%REPO_URL%"=="" (
    echo 地址不能为空！
    pause
    exit /b
)

echo.
echo [0/5] 配置 Git 用户信息...
git config user.email "auto@example.com"
git config user.name "Auto User"

echo [1/5] 初始化仓库...
git init

echo [2/5] 添加文件...
git add .

echo [3/5] 提交更改...
git commit -m "Initial commit: Upload One-API Client"

echo [4/5] 关联远程仓库...
git branch -M main
git remote remove origin 2>nul
git remote add origin %REPO_URL%

echo [5/5] 推送到 GitHub...
echo 注意：如果弹出登录窗口，请在窗口中登录你的 GitHub 账号。
git push -u origin main

if %ERRORLEVEL% EQU 0 (
    echo.
    echo [成功] 代码已上传！
    echo 请访问你的 GitHub 仓库页面查看 Actions 构建进度。
) else (
    echo.
    echo [失败] 上传过程中出现错误，请检查网络或账号权限。
)

pause
