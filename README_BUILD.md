# 如何构建 Android APK

本项目已配置 GitHub Actions 自动构建。你不需要在本地安装 Flutter 环境，只需将代码上传到 GitHub 即可。

## 第一步：准备 GitHub 仓库
1. 登录 [GitHub](https://github.com/)。
2. 点击右上角的 **+** 号，选择 **New repository**。
3. 输入仓库名称（例如 `one-api-client`），点击 **Create repository**。

## 第二步：上传代码
你需要将本地代码推送到刚才创建的仓库。

### 如果你已安装 Git：
在项目根目录打开终端（CMD 或 PowerShell），运行以下命令（替换 `<你的仓库地址>`）：
```bash
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin <你的仓库地址>
git push -u origin main
```

### 如果你没有安装 Git：
1. 下载并安装 [Git for Windows](https://git-scm.com/download/win)。
2. 安装完成后，重新打开终端运行上述命令。
3. 或者使用 [GitHub Desktop](https://desktop.github.com/) 等图形化工具上传。

## 第三步：下载 APK
1. 代码上传成功后，打开你的 GitHub 仓库页面。
2. 点击顶部的 **Actions** 标签。
3. 你会看到一个名为 **Build Android APK** 的工作流正在运行（黄色旋转图标）。
4. 等待它变成绿色对勾（约 3-5 分钟）。
5. 点击该次运行记录，在页面底部的 **Artifacts** 区域，点击 **app-release-apk** 下载。
6. 解压下载的文件，即可得到 `app-release.apk`，发送到手机安装即可。
