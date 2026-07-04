# ChronoVolume-原型程序安装助手
# Windows 图形化安装助手。启动它不需要预先安装 Python。

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RequiredPackages = @("PySide6", "opencv-python", "numpy")
$script:AppTitle = "ChronoVolume-原型程序安装助手"
$script:DefaultScriptName = "ChronoVolume-原型程序.py"
$script:LastRunLogName = "ChronoVolume-原型程序启动日志.txt"

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $env:Path = $parts -join ";"
}

function Add-Log {
    param([string]$Message)

    if ($null -eq $script:LogBox) {
        return
    }

    $time = Get-Date -Format "HH:mm:ss"
    $script:LogBox.AppendText("[$time] $Message`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Quote-ProcessArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Join-ProcessArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join " ")
}

function Show-Error {
    param([string]$Message)
    Add-Log "ERROR: $Message"
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        $script:AppTitle,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}

function Drain-LogFile {
    param(
        [string]$Path,
        [ref]$DisplayedLineCount
    )

    if (-not (Test-Path $Path)) {
        return
    }
    $lines = Get-Content $Path -ErrorAction SilentlyContinue
    if ($null -eq $lines) {
        return
    }
    if ($lines -isnot [System.Array]) {
        $lines = @($lines)
    }
    while ($DisplayedLineCount.Value -lt $lines.Count) {
        Add-Log ($lines[$DisplayedLineCount.Value].ToString())
        $DisplayedLineCount.Value += 1
    }
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $quotedArgs = Join-ProcessArguments -Arguments $Arguments

    Add-Log "> $FilePath $quotedArgs"

    $logPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ChronoVolumeSetup-" + [Guid]::NewGuid().ToString("N") + ".log")
    $quotedLogPath = Quote-ProcessArgument $logPath
    $commandLine = (Quote-ProcessArgument $FilePath)
    if (-not [string]::IsNullOrWhiteSpace($quotedArgs)) {
        $commandLine += " $quotedArgs"
    }
    $commandLine += " > $quotedLogPath 2>&1"

    $process = New-Object System.Diagnostics.Process
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "cmd.exe"
    $startInfo.Arguments = "/d /c $commandLine"
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process.StartInfo = $startInfo

    $displayedLineCount = 0

    try {
        if (-not $process.Start()) {
            throw "无法启动命令：$FilePath"
        }

        while (-not $process.HasExited) {
            Drain-LogFile -Path $logPath -DisplayedLineCount ([ref]$displayedLineCount)
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }

        $process.WaitForExit()
        Drain-LogFile -Path $logPath -DisplayedLineCount ([ref]$displayedLineCount)
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
        if (Test-Path $logPath) {
            Remove-Item $logPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($exitCode -ne 0) {
        throw "$FilePath exited with code $exitCode."
    }
}

function Resolve-PythonCandidate {
    param(
        [string]$Command,
        [string[]]$PrefixArguments = @()
    )

    try {
        $arguments = @()
        $arguments += $PrefixArguments
        $arguments += @("-c", "import sys; print(sys.executable)")
        $result = & $Command @arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $result) {
            $path = ($result | Select-Object -Last 1).ToString().Trim()
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
                return $path
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Get-PythonExecutable {
    Refresh-Path

    if (Get-Command py -ErrorAction SilentlyContinue) {
        $launcherPython = Resolve-PythonCandidate -Command "py" -PrefixArguments @("-3")
        if ($launcherPython) {
            return $launcherPython
        }
    }

    foreach ($commandName in @("python", "python3")) {
        if (Get-Command $commandName -ErrorAction SilentlyContinue) {
            $python = Resolve-PythonCandidate -Command $commandName
            if ($python) {
                return $python
            }
        }
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $patterns = @()
    if ($env:LOCALAPPDATA) {
        $patterns += Join-Path $env:LOCALAPPDATA "Programs\Python\Python*\python.exe"
    }
    if ($env:ProgramFiles) {
        $patterns += Join-Path $env:ProgramFiles "Python*\python.exe"
    }
    if ($programFilesX86) {
        $patterns += Join-Path $programFilesX86 "Python*\python.exe"
    }

    foreach ($pattern in $patterns) {
        $items = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
        foreach ($item in $items) {
            $resolved = Resolve-PythonCandidate -Command $item.FullName
            if ($resolved) {
                return $resolved
            }
        }
    }

    return $null
}

function Get-FFmpegExecutable {
    Refresh-Path
    $command = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($candidate in @(
        "C:\ffmpeg\bin\ffmpeg.exe",
        "C:\Program Files\ffmpeg\bin\ffmpeg.exe",
        "C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe"
    )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-SelectedScriptPath {
    $path = $script:ScriptPathBox.Text.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "请先选择 ChronoVolume-原型程序.py。"
    }
    if (-not (Test-Path $path)) {
        throw "选择的程序文件不存在：$path"
    }
    return (Resolve-Path $path).Path
}

function Get-ProjectDirectory {
    $scriptPath = Get-SelectedScriptPath
    return Split-Path -Parent $scriptPath
}

function Get-VenvPythonPath {
    $projectDir = Get-ProjectDirectory
    return Join-Path $projectDir ".venv\Scripts\python.exe"
}

function Test-AppDependenciesReady {
    try {
        $venvPython = Get-VenvPythonPath
        if (-not (Test-Path $venvPython)) {
            return $false
        }

        $code = "import PySide6, cv2, numpy; print('ok')"
        $output = & $venvPython -c $code 2>$null
        return ($LASTEXITCODE -eq 0 -and $null -ne $output)
    } catch {
        return $false
    }
}

function Set-StatusLabel {
    param(
        [System.Windows.Forms.Label]$Label,
        [bool]$Ok,
        [string]$Text
    )

    if ($Ok) {
        $Label.Text = "已就绪 - $Text"
        $Label.ForeColor = [System.Drawing.Color]::FromArgb(22, 120, 54)
    } else {
        $Label.Text = "缺失 - $Text"
        $Label.ForeColor = [System.Drawing.Color]::FromArgb(178, 34, 34)
    }
}

function Update-EnvironmentStatus {
    try {
        $python = Get-PythonExecutable
        if ($python) {
            Set-StatusLabel -Label $script:PythonStatusLabel -Ok $true -Text $python
        } else {
            Set-StatusLabel -Label $script:PythonStatusLabel -Ok $false -Text "Python"
        }

        $ffmpeg = Get-FFmpegExecutable
        if ($ffmpeg) {
            Set-StatusLabel -Label $script:FFmpegStatusLabel -Ok $true -Text $ffmpeg
        } else {
            Set-StatusLabel -Label $script:FFmpegStatusLabel -Ok $false -Text "FFmpeg"
        }

        $venvPython = $null
        try {
            $venvPython = Get-VenvPythonPath
        } catch {
            $venvPython = $null
        }

        if ($venvPython -and (Test-Path $venvPython)) {
            Set-StatusLabel -Label $script:VenvStatusLabel -Ok $true -Text $venvPython
        } else {
            Set-StatusLabel -Label $script:VenvStatusLabel -Ok $false -Text ".venv"
        }

        if (Test-AppDependenciesReady) {
            Set-StatusLabel -Label $script:DependencyStatusLabel -Ok $true -Text "PySide6 / OpenCV / NumPy"
        } else {
            Set-StatusLabel -Label $script:DependencyStatusLabel -Ok $false -Text "PySide6 / OpenCV / NumPy"
        }
    } catch {
        Add-Log "状态刷新失败：$($_.Exception.Message)"
    }
}

function Set-Busy {
    param([bool]$Busy)

    foreach ($button in $script:TaskButtons) {
        $button.Enabled = -not $Busy
    }

    if ($Busy) {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    } else {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Task {
    param([scriptblock]$Action)

    Set-Busy $true
    try {
        & $Action
    } catch {
        Show-Error $_.Exception.Message
    } finally {
        Update-EnvironmentStatus
        Set-Busy $false
    }
}

function Install-Python {
    $python = Get-PythonExecutable
    if ($python) {
        Add-Log "Python 已可用：$python"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Add-Log "未找到 winget，正在打开 Python 下载页面。"
        Start-Process "https://www.python.org/downloads/windows/"
        throw "请在打开的网页中安装 Python。安装时勾选 'Add python.exe to PATH'，然后重新打开本助手。"
    }

    Add-Log "正在通过 winget 安装 Python 3..."
    Invoke-External -FilePath "winget" -Arguments @(
        "install",
        "--id", "Python.Python.3.13",
        "-e",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    ) -WorkingDirectory $script:Root

    Refresh-Path
    $python = Get-PythonExecutable
    if (-not $python) {
        throw "Python 安装已结束，但当前会话还没找到 Python。请关闭并重新打开本助手。"
    }

    Add-Log "Python 已安装：$python"
}

function Install-FFmpeg {
    $ffmpeg = Get-FFmpegExecutable
    if ($ffmpeg) {
        Add-Log "FFmpeg 已可用：$ffmpeg"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Add-Log "未找到 winget，正在打开 FFmpeg 下载页面。"
        Start-Process "https://ffmpeg.org/download.html"
        throw "请在打开的网页中安装 FFmpeg，然后重新打开本助手。"
    }

    Add-Log "正在通过 winget 安装 FFmpeg..."
    Invoke-External -FilePath "winget" -Arguments @(
        "install",
        "--id", "Gyan.FFmpeg",
        "-e",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    ) -WorkingDirectory $script:Root

    Refresh-Path
    $ffmpeg = Get-FFmpegExecutable
    if (-not $ffmpeg) {
        throw "FFmpeg 安装已结束，但当前会话还没找到 ffmpeg.exe。请关闭并重新打开本助手。"
    }

    Add-Log "FFmpeg 已安装：$ffmpeg"
}

function Install-AppDependencies {
    $scriptPath = Get-SelectedScriptPath
    $projectDir = Split-Path -Parent $scriptPath
    $python = Get-PythonExecutable

    if (-not $python) {
        throw "还没有安装 Python。"
    }

    $venvDir = Join-Path $projectDir ".venv"
    $venvPython = Join-Path $venvDir "Scripts\python.exe"

    if (-not (Test-Path $venvPython)) {
        Add-Log "正在创建独立运行环境：$venvDir"
        Invoke-External -FilePath $python -Arguments @("-m", "venv", $venvDir) -WorkingDirectory $projectDir
    } else {
        Add-Log "独立运行环境已存在：$venvDir"
    }

    Add-Log "正在升级 pip..."
    Invoke-External -FilePath $venvPython -Arguments @("-m", "pip", "install", "--upgrade", "pip") -WorkingDirectory $projectDir

    Add-Log "正在安装程序依赖..."
    $installArgs = @("-m", "pip", "install") + $script:RequiredPackages
    Invoke-External -FilePath $venvPython -Arguments $installArgs -WorkingDirectory $projectDir

    Add-Log "正在验证依赖..."
    Invoke-External -FilePath $venvPython -Arguments @("-c", "import PySide6, cv2, numpy; print('依赖验证通过')") -WorkingDirectory $projectDir

    Add-Log "依赖安装完成。"
}

function Start-HiddenPythonWithLog {
    param(
        [string]$PythonPath,
        [string]$ScriptPath,
        [string]$WorkingDirectory
    )

    $logPath = Join-Path $WorkingDirectory $script:LastRunLogName
    if (Test-Path $logPath) {
        Remove-Item $logPath -Force
    }

    $quotedPython = Quote-ProcessArgument $PythonPath
    $quotedScript = Quote-ProcessArgument $ScriptPath
    $quotedLog = Quote-ProcessArgument $logPath
    $cmdLine = "/d /c $quotedPython $quotedScript > $quotedLog 2>&1"

    $process = New-Object System.Diagnostics.Process
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "cmd.exe"
    $startInfo.Arguments = $cmdLine
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process.StartInfo = $startInfo

    Add-Log "启动日志文件：$logPath"
    if (-not $process.Start()) {
        throw "无法启动 ChronoVolume-原型程序。"
    }

    $deadline = (Get-Date).AddSeconds(4)
    while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }

    if ($process.HasExited) {
        $exitCode = $process.ExitCode
        $logText = ""
        if (Test-Path $logPath) {
            $logText = (Get-Content $logPath -Raw -ErrorAction SilentlyContinue)
        }
        if ([string]::IsNullOrWhiteSpace($logText)) {
            $logText = "程序启动后很快退出，但没有写出错误信息。"
        }
        Add-Log "程序已退出，退出码：$exitCode"
        foreach ($line in ($logText -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Add-Log $line
            }
        }
        throw "ChronoVolume-原型程序启动失败或立即退出。错误详情已显示在运行日志中，也保存在：$logPath"
    }

    Add-Log "程序已经启动。如果主窗口没有出现，请查看启动日志文件。"
}

function Run-ChronoVolumePrototype {
    $scriptPath = Get-SelectedScriptPath
    $projectDir = Split-Path -Parent $scriptPath
    $venvPython = Join-Path $projectDir ".venv\Scripts\python.exe"

    if (-not (Test-Path $venvPython)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "未找到本程序的独立 Python 环境。现在安装依赖吗？",
            $script:AppTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
        Install-AppDependencies
    }

    if (-not (Test-AppDependenciesReady)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "检测到依赖没有安装完整。现在重新安装/修复依赖吗？",
            $script:AppTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            throw "依赖没有安装完整，暂时不能运行程序。"
        }
        Install-AppDependencies
    }

    Add-Log "正在启动 ChronoVolume-原型程序..."
    Start-HiddenPythonWithLog -PythonPath $venvPython -ScriptPath $scriptPath -WorkingDirectory $projectDir
}

function Run-FullSetup {
    Install-Python
    Install-FFmpeg
    Install-AppDependencies
    Add-Log "完整安装已完成。现在可以点击“运行程序”。"
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $label.Size = New-Object System.Drawing.Size -ArgumentList $Width, $Height
    $label.Font = New-Object System.Drawing.Font -ArgumentList "Segoe UI", 9
    return $label
}

function New-Button {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $button.Size = New-Object System.Drawing.Size -ArgumentList $Width, $Height
    $button.Font = New-Object System.Drawing.Font -ArgumentList "Segoe UI", 9
    return $button
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = $script:AppTitle
$script:Form.StartPosition = "CenterScreen"
$script:Form.Size = New-Object System.Drawing.Size -ArgumentList 900, 650
$script:Form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 820, 600

$title = New-Label -Text "ChronoVolume-原型程序安装助手" -X 16 -Y 14 -Width 840 -Height 28
$title.Font = New-Object System.Drawing.Font -ArgumentList "Segoe UI", 14, ([System.Drawing.FontStyle]::Bold)
$script:Form.Controls.Add($title)

$description = New-Label -Text "用于安装 Python、FFmpeg，以及 ChronoVolume-原型程序 需要的运行依赖。" -X 18 -Y 48 -Width 840 -Height 24
$script:Form.Controls.Add($description)

$scriptLabel = New-Label -Text "程序文件：" -X 18 -Y 86 -Width 100 -Height 24
$script:Form.Controls.Add($scriptLabel)

$script:ScriptPathBox = New-Object System.Windows.Forms.TextBox
$script:ScriptPathBox.Location = New-Object System.Drawing.Point -ArgumentList 118, 84
$script:ScriptPathBox.Size = New-Object System.Drawing.Size -ArgumentList 610, 26
$script:ScriptPathBox.Font = New-Object System.Drawing.Font -ArgumentList "Segoe UI", 9
$defaultScript = Join-Path $script:Root $script:DefaultScriptName
if (Test-Path $defaultScript) {
    $script:ScriptPathBox.Text = $defaultScript
} else {
    $script:ScriptPathBox.Text = Join-Path (Split-Path -Parent $script:Root) $script:DefaultScriptName
}
$script:Form.Controls.Add($script:ScriptPathBox)

$browseButton = New-Button -Text "浏览..." -X 740 -Y 82 -Width 120 -Height 30
$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "选择 ChronoVolume-原型程序.py"
    $dialog.Filter = "Python 程序 (*.py)|*.py|所有文件 (*.*)|*.*"
    $currentText = $script:ScriptPathBox.Text.Trim().Trim('"')
    if (-not [string]::IsNullOrWhiteSpace($currentText)) {
        $currentDir = Split-Path -Parent $currentText -ErrorAction SilentlyContinue
        if ($currentDir -and (Test-Path $currentDir)) {
            $dialog.InitialDirectory = $currentDir
        }
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:ScriptPathBox.Text = $dialog.FileName
        Update-EnvironmentStatus
    }
})
$script:Form.Controls.Add($browseButton)

$statusGroup = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text = "环境状态"
$statusGroup.Location = New-Object System.Drawing.Point -ArgumentList 18, 126
$statusGroup.Size = New-Object System.Drawing.Size -ArgumentList 842, 136
$statusGroup.Font = New-Object System.Drawing.Font -ArgumentList "Segoe UI", 9
$script:Form.Controls.Add($statusGroup)

$script:PythonStatusLabel = New-Label -Text "缺失 - Python" -X 16 -Y 26 -Width 800 -Height 22
$statusGroup.Controls.Add($script:PythonStatusLabel)

$script:FFmpegStatusLabel = New-Label -Text "缺失 - FFmpeg" -X 16 -Y 52 -Width 800 -Height 22
$statusGroup.Controls.Add($script:FFmpegStatusLabel)

$script:VenvStatusLabel = New-Label -Text "缺失 - .venv" -X 16 -Y 78 -Width 800 -Height 22
$statusGroup.Controls.Add($script:VenvStatusLabel)

$script:DependencyStatusLabel = New-Label -Text "缺失 - PySide6 / OpenCV / NumPy" -X 16 -Y 104 -Width 800 -Height 22
$statusGroup.Controls.Add($script:DependencyStatusLabel)

$fullSetupButton = New-Button -Text "完整安装/修复" -X 18 -Y 278 -Width 150 -Height 36
$checkButton = New-Button -Text "检查状态" -X 178 -Y 278 -Width 120 -Height 36
$pythonButton = New-Button -Text "安装 Python" -X 308 -Y 278 -Width 120 -Height 36
$ffmpegButton = New-Button -Text "安装 FFmpeg" -X 438 -Y 278 -Width 130 -Height 36
$depsButton = New-Button -Text "安装依赖" -X 578 -Y 278 -Width 120 -Height 36
$runButton = New-Button -Text "运行程序" -X 18 -Y 326 -Width 150 -Height 36
$openFolderButton = New-Button -Text "打开程序文件夹" -X 178 -Y 326 -Width 150 -Height 36

$script:TaskButtons = @(
    $fullSetupButton,
    $checkButton,
    $pythonButton,
    $ffmpegButton,
    $depsButton,
    $runButton,
    $openFolderButton,
    $browseButton
)

$fullSetupButton.Add_Click({ Invoke-Task { Run-FullSetup } })
$checkButton.Add_Click({ Invoke-Task { Update-EnvironmentStatus; Add-Log "状态检查完成。" } })
$pythonButton.Add_Click({ Invoke-Task { Install-Python } })
$ffmpegButton.Add_Click({ Invoke-Task { Install-FFmpeg } })
$depsButton.Add_Click({ Invoke-Task { Install-AppDependencies } })
$runButton.Add_Click({ Invoke-Task { Run-ChronoVolumePrototype } })
$openFolderButton.Add_Click({
    Invoke-Task {
        $dir = Get-ProjectDirectory
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $dir)
    }
})

foreach ($button in @($fullSetupButton, $checkButton, $pythonButton, $ffmpegButton, $depsButton, $runButton, $openFolderButton)) {
    $script:Form.Controls.Add($button)
}

$logLabel = New-Label -Text "运行日志：" -X 18 -Y 380 -Width 120 -Height 22
$script:Form.Controls.Add($logLabel)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point -ArgumentList 18, 406
$script:LogBox.Size = New-Object System.Drawing.Size -ArgumentList 842, 184
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = "Vertical"
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 9
$script:Form.Controls.Add($script:LogBox)

$script:Form.Add_Shown({
    Add-Log "安装助手已启动。"
    Add-Log "需要安装的依赖：$($script:RequiredPackages -join ', ')"
    Update-EnvironmentStatus
})

[void]$script:Form.ShowDialog()
