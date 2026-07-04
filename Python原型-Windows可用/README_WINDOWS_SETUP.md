# ChronoVolume-原型程序 Windows 图形化安装助手

这个文件夹里的安装助手用于 Windows 电脑。它本身不需要 Python，也不是 `.py` 程序；双击 `.cmd` 后会打开一个中文图形界面，用来安装 Python、FFmpeg 和 `ChronoVolume-原型程序.py` 需要的依赖。

## 文件说明

- `Start-ChronoVolume-Prototype-Setup.cmd`：给普通用户双击启动的入口。
- `ChronoVolumePrototypeSetupAssistant.ps1`：真正的 Windows 中文图形界面程序。
- `ChronoVolume-原型程序.py`：已经改名后的 Python 原型程序，窗口标题也是 `ChronoVolume-原型程序`。
- `requirements-chronovolume-prototype.txt`：记录原型程序需要的 Python 包。
- `使用方法与注意事项.md`：更完整的使用流程、注意事项和常见问题。

## 给 Windows 用户的用法

1. 新建一个文件夹，例如 `ChronoVolume-原型程序`。
2. 把本文件夹里的文件放进去。
3. 双击 `Start-ChronoVolume-Prototype-Setup.cmd`。
4. 如果程序文件路径没有自动选中，点击 `浏览...` 选择 `ChronoVolume-原型程序.py`。
5. 点击 `完整安装/修复`。
6. 安装完成后点击 `运行程序`。

## 如果之前运行失败

如果点 `运行程序` 后只看到黑色窗口一闪而过，请使用新版安装助手重新点击：

1. `检查状态`
2. 如果 `PySide6 / OpenCV / NumPy` 显示缺失，点击 `安装依赖`
3. 再点击 `运行程序`

新版助手会把启动错误写入：

`ChronoVolume-原型程序启动日志.txt`

这个日志会出现在 `ChronoVolume-原型程序.py` 同一个文件夹里。

## 它会安装什么

- Python 3，优先通过 Windows 自带的 `winget` 安装。
- FFmpeg，优先通过 `winget install Gyan.FFmpeg` 安装。
- Python 依赖：
  - `PySide6`
  - `opencv-python`
  - `numpy`

它会在 `ChronoVolume-原型程序.py` 所在文件夹创建 `.venv`，依赖会安装到这个独立环境里，不会污染系统 Python。

## 注意

`完整安装/修复` 可能需要几分钟，尤其是第一次安装 PySide6。新版助手会实时显示安装日志；只要日志仍在变化，就不是卡死。

如果 Windows 提示是否允许运行脚本，选择允许即可。这个助手只负责安装运行环境和启动你的 Python 程序，不会上传文件，也不会读取 GitHub token 或密码。

如果 `winget` 不存在，助手会打开 Python 或 FFmpeg 的官方下载页面，让用户手动安装。
