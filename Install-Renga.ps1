<#
.SYNOPSIS
    Автоматическая установка/обновление Renga Professional, удаление предыдущих версий
    и настройка конфигурации лицензирования для всех профилей пользователей.

.DESCRIPTION
    1. Принудительно завершает запущенные процессы Renga (Renga.exe, AecApp.exe).
    2. Находит в реестре и тихо удаляет любые установленные ранее версии Renga.
    3. Выполняет тихую установку новой версии из RengaProfessionalSetup.exe.
    4. Развертывает и настраивает Settings.ini и файлы конфигурации:
       - Во все существующие профили пользователей (C:\Users\*).
       - В профиль по умолчанию (C:\Users\Default).
       - Настраивает Active Setup для автоматической настройки новых профилей.
       - Подставляет имя текущего компьютера в CollaborationUserName.
       - Настраивает адрес сервера лицензий v-as2.ygk.ru.
#>

[CmdletBinding()]
param(
    [switch]$Silent,
    [string]$LicenseServer = "v-as2.ygk.ru",
    [string]$LogFile = "C:\Windows\Temp\Renga_Deploy.log"
)

# Проверка прав администратора
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    if (-not $Silent) {
        Write-Host "Запрос повышения прав Администратора..." -ForegroundColor Yellow
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    } else {
        Write-Error "Ошибка: Скрипт должен выполняться с правами Администратора!"
        exit 1
    }
}

# Функция логирования
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    # Вывод в консоль цветом
    switch ($Level) {
        "INFO"    { Write-Host $logLine -ForegroundColor Cyan }
        "WARN"    { Write-Host $logLine -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logLine -ForegroundColor Red }
        "SUCCESS" { Write-Host $logLine -ForegroundColor Green }
    }

    # Запись в файл
    try {
        $logDir = Split-Path -Parent $LogFile
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $logLine -Encoding UTF8
    } catch {}
}

# Конвертация строки с не-ASCII символами в формат Qt QSettings (\xXXXX)
function Convert-ToQSettingsValue ([string]$str) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($char in $str.ToCharArray()) {
        $val = [int]$char
        if ($val -gt 127) {
            $null = $sb.Append([string]::Format('\x{0:x}', $val))
        } else {
            $null = $sb.Append($char)
        }
    }
    return $sb.ToString()
}

# Разбор и запуск строки деинсталляции
function Invoke-UninstallString ([string]$commandString) {
    $trimmed = $commandString.Trim()
    $exePath = ""
    $arguments = ""

    if ($trimmed -match '^"([^"]+)"\s*(.*)$') {
        $exePath = $matches[1]
        $arguments = $matches[2]
    } elseif ($trimmed -match '^([^\s]+)\s*(.*)$') {
        $exePath = $matches[1]
        $arguments = $matches[2]
    } else {
        $exePath = $trimmed
        $arguments = ""
    }

    # Заменяем флаг /modify на /uninstall для пакетов WiX Burn
    $arguments = $arguments -replace '(?i)/modify', '/uninstall'

    # Добавляем флаги тихого режима, если их нет
    if ($arguments -notmatch '(?i)/uninstall') {
        $arguments = "/uninstall $arguments"
    }
    if ($arguments -notmatch '(?i)/quiet' -and $arguments -notmatch '(?i)/silent' -and $arguments -notmatch '(?i)/qn') {
        $arguments = "$arguments /quiet /norestart"
    }

    Write-Log "Запуск деинсталлятора: `"$exePath`" $arguments"
    try {
        if (Test-Path $exePath) {
            $proc = Start-Process -FilePath $exePath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
            Write-Log "Процесс удаления завершен с кодом: $($proc.ExitCode)"
        } else {
            $cleanCmd = $commandString -replace '(?i)/modify', '/uninstall'
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$cleanCmd /quiet /norestart`"" -Wait -PassThru -NoNewWindow
            Write-Log "Процесс удаления через cmd завершен с кодом: $($proc.ExitCode)"
        }
    } catch {
        Write-Log "Ошибка при запуске деинсталлятора: $($_.Exception.Message)" "ERROR"
    }
}

# 1. Принудительное завершение процессов
function Stop-RengaProcesses {
    Write-Log "Проверка активных процессов Renga..."
    $processNames = @("Renga", "AecApp", "RengaProfessionalSetup", "RengaStandardSetup")
    $runningProcesses = Get-Process -Name $processNames -ErrorAction SilentlyContinue

    if ($runningProcesses) {
        foreach ($proc in $runningProcesses) {
            Write-Log "Завершение процесса $($proc.ProcessName) (PID: $($proc.Id))..." "WARN"
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            } catch {
                Write-Log "Не удалось завершить процесс PID $($proc.Id): $($_.Exception.Message)" "ERROR"
            }
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Log "Активные процессы Renga не обнаружены."
    }
}

# 2. Поиск и удаление старых версий Renga
function Remove-OldRengaVersions {
    Write-Log "Поиск установленных копий Renga в реестре..."
    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $installed = Get-ItemProperty -Path $regRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -match 'Renga' } |
        Group-Object -Property DisplayName | ForEach-Object { $_.Group[0] }

    if (-not $installed -or $installed.Count -eq 0) {
        Write-Log "Предыдущие версии Renga не найдены."
        return
    }

    foreach ($item in $installed) {
        $displayName = $item.DisplayName
        $displayVersion = $item.DisplayVersion
        $uninstallString = $item.UninstallString
        $quietUninstallString = $item.QuietUninstallString

        Write-Log "Найдена установленная версия: '$displayName' ($displayVersion)"

        # Проверяем, не является ли это MSI
        if ($uninstallString -match '(?i)msiexec(\.exe)?' -or ($item.PSChildName -match '^\{[0-9a-fA-F\-]{36}\}$')) {
            $guid = if ($uninstallString -match '\{[0-9a-fA-F\-]{36}\}') { $matches[0] } else { $item.PSChildName }
            Write-Log "Удаление через MSI: msiexec.exe /x `"$guid`" /qn /norestart"
            $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x `"$guid`" /qn /norestart" -Wait -PassThru
            Write-Log "MSI удаление завершено с кодом: $($p.ExitCode)"
        }
        elseif ($quietUninstallString) {
            Write-Log "Выполнение тихого удаления: $quietUninstallString"
            Invoke-UninstallString -commandString $quietUninstallString
        }
        elseif ($uninstallString) {
            Invoke-UninstallString -commandString $uninstallString
        }
    }

    # Небольшая пауза после удаления
    Start-Sleep -Seconds 3
}

# 3. Установка новой версии Renga Professional
function Install-NewRenga {
    $installerPath = Join-Path $PSScriptRoot "RengaProfessionalSetup.exe"

    if (-not (Test-Path $installerPath)) {
        Write-Log "ОШИБКА: Файл установщика не найден: $installerPath" "ERROR"
        throw "Installer not found at $installerPath"
    }

    $setupLog = "C:\Windows\Temp\Renga_Setup_Install.log"
    $installArgs = "/install /quiet /norestart /log `"$setupLog`""

    Write-Log "Запуск установки: `"$installerPath`" $installArgs"
    Write-Log "Пожалуйста, подождите, идет установка Renga Professional..."

    $installProc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru

    Write-Log "Код завершения установщика: $($installProc.ExitCode)"

    # 0 = Success, 3010 = Success (Reboot Required), 1641 = Success (Reboot Initiated)
    $successCodes = @(0, 3010, 1641)
    if ($successCodes -contains $installProc.ExitCode) {
        Write-Log "Установка Renga Professional успешно завершена! (Код возврата: $($installProc.ExitCode))" "SUCCESS"
        if ($installProc.ExitCode -eq 3010 -or $installProc.ExitCode -eq 1641) {
            Write-Log "Примечание: требуется перезагрузка ПК для завершения регистрации компонентов." "WARN"
        }

        # Проверяем наличие установленного Renga.exe
        $installedExe = "${env:ProgramFiles}\Renga Professional\Renga.exe"
        if (-not (Test-Path $installedExe)) {
            Write-Log "Основной исполняемый файл Renga.exe еще не найден. Проверка кэшированного MSI пакета..." "WARN"
            $cachedMsi = Get-ChildItem "C:\ProgramData\Package Cache" -Recurse -Filter "Renga.msi" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '9\.2' } | Select-Object -First 1
            if ($cachedMsi) {
                Write-Log "Установка пакета Renga.msi напрямую: $($cachedMsi.FullName)..."
                $msiProc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($cachedMsi.FullName)`" /qn /norestart" -Wait -PassThru
                Write-Log "Установка Renga.msi завершена с кодом: $($msiProc.ExitCode)"
            }
        }
    } else {
        Write-Log "ОШИБКА: Установка завершилась с кодом ошибки $($installProc.ExitCode)!" "ERROR"
        if (Test-Path $setupLog) {
            Write-Log "Последние 15 строк журнала установщика ($setupLog):" "ERROR"
            Get-Content -Path $setupLog -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Log "  $_" "ERROR"
            }
        }
        throw "Setup exited with error code $($installProc.ExitCode)"
    }
}

# 4. Развертывание конфигурации во все профили пользователей
function Deploy-Configurations {
    $sourceDir = Join-Path $PSScriptRoot "Renga Software\Renga Professional"

    if (-not (Test-Path $sourceDir)) {
        Write-Log "ОШИБКА: Папка с шаблоном настроек не найдена: $sourceDir" "ERROR"
        return
    }

    $settingsIniTemplatePath = Join-Path $sourceDir "Settings.ini"
    if (-not (Test-Path $settingsIniTemplatePath)) {
        Write-Log "ОШИБКА: Файл Settings.ini не найден в $sourceDir" "ERROR"
        return
    }

    $computerName = $env:COMPUTERNAME
    Write-Log "Развертывание настроек. Имя компьютера для совместной работы: $computerName"
    Write-Log "Сервер лицензий: $LicenseServer"

    # Получаем список файлов для копирования (все json-файлы)
    $jsonFiles = Get-ChildItem -Path $sourceDir -Filter "*.json" -File

    # Находим все реальные профили пользователей + профиль Default
    $userProfiles = Get-ChildItem -Path "C:\Users" -Directory -Force | Where-Object {
        ((-not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -and
         ($_.Name -ne "Public") -and
         ($_.Name -ne "Default User") -and
         ($_.Name -ne "All Users"))
    }

    $rawTemplate = [System.IO.File]::ReadAllText($settingsIniTemplatePath, [System.Text.Encoding]::UTF8)

    foreach ($profile in $userProfiles) {
        $profilePath = $profile.FullName
        $targetRengaDir = Join-Path $profilePath "AppData\Local\Renga Software\Renga Professional"

        Write-Log "Настройка профиля: $($profile.Name) ($targetRengaDir)"

        try {
            if (-not (Test-Path $targetRengaDir)) {
                New-Item -ItemType Directory -Path $targetRengaDir -Force | Out-Null
            }

            # Копируем все JSON-файлы настроек
            foreach ($jsonFile in $jsonFiles) {
                Copy-Item -Path $jsonFile.FullName -Destination $targetRengaDir -Force
            }

            # Формируем кастомизированный Settings.ini для этого профиля
            $customSettings = $rawTemplate

            # 1. Подстановка CollaborationUserName = ИМЯ_КОМПЬЮТЕРА
            $customSettings = $customSettings -replace '(?m)^CollaborationUserName=.*$', "CollaborationUserName=$computerName"

            # 2. Подстановка сервера лицензий
            $customSettings = $customSettings -replace '(?m)^Servers=.*$', "Servers=$LicenseServer"
            $customSettings = $customSettings -replace '(?m)^BroadcastSearch=.*$', "BroadcastSearch=true"

            # 3. Адаптация пути к ifc_geometry_type_settings.json для этого конкретного профиля
            $localIfcPath = "$($targetRengaDir.Replace('\', '/'))/ifc_geometry_type_settings.json"
            $encodedIfcPath = Convert-ToQSettingsValue $localIfcPath
            $customSettings = $customSettings -replace '(?m)^IfcGeometryExportSettingsFilePath=.*$', "IfcGeometryExportSettingsFilePath=$encodedIfcPath"

            # Сохраняем в UTF-8 без BOM
            $targetSettingsFile = Join-Path $targetRengaDir "Settings.ini"
            [System.IO.File]::WriteAllText($targetSettingsFile, $customSettings, [System.Text.UTF8Encoding]::new($false))

        } catch {
            Write-Log "Ошибка при настройке профиля $($profile.Name): $($_.Exception.Message)" "ERROR"
        }
    }

    # Настройка Active Setup для будущих новых пользователей ПК
    try {
        Register-ActiveSetup -SourceSettingsDir $sourceDir -LicenseServer $LicenseServer
    } catch {
        Write-Log "Предупреждение при настройке Active Setup: $($_.Exception.Message)" "WARN"
    }

    Write-Log "Конфигурация лицензий и настроек успешно применена ко всем профилям!" "SUCCESS"
}

# Регистрация компонента Active Setup в Windows для новых пользователей
function Register-ActiveSetup {
    param(
        [string]$SourceSettingsDir,
        [string]$LicenseServer
    )

    $globalConfigDir = "C:\ProgramData\RengaDeploymentConfig"
    if (-not (Test-Path $globalConfigDir)) {
        New-Item -ItemType Directory -Path $globalConfigDir -Force | Out-Null
    }

    # Копируем эталонную папку настроек в ProgramData
    Copy-Item -Path "$SourceSettingsDir\*" -Destination $globalConfigDir -Recurse -Force

    # Создаем скрипт инициализации профиля
    $initScriptPath = Join-Path $globalConfigDir "Init-UserProfileRenga.ps1"
    $initTemplate = @'
$ErrorActionPreference = 'SilentlyContinue'
$src = 'C:\ProgramData\RengaDeploymentConfig'
$dest = "$env:LOCALAPPDATA\Renga Software\Renga Professional"
if (-not (Test-Path $dest)) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}
Get-ChildItem -Path $src -Filter "*.json" | Copy-Item -Destination $dest -Force
if (Test-Path "$src\Settings.ini") {
    $content = [System.IO.File]::ReadAllText("$src\Settings.ini", [System.Text.Encoding]::UTF8)
    $content = $content -replace '(?m)^CollaborationUserName=.*$', "CollaborationUserName=$env:COMPUTERNAME"
    $content = $content -replace '(?m)^Servers=.*$', "Servers=__LICENSE_SERVER__"
    $targetIfc = ("$dest/ifc_geometry_type_settings.json").Replace('\', '/')
    $sb = New-Object System.Text.StringBuilder
    foreach ($char in $targetIfc.ToCharArray()) {
        $val = [int]$char
        if ($val -gt 127) {
            $null = $sb.Append([string]::Format('\x{0:x}', $val))
        } else {
            $null = $sb.Append($char)
        }
    }
    $encodedPath = $sb.ToString()
    $content = $content -replace '(?m)^IfcGeometryExportSettingsFilePath=.*$', "IfcGeometryExportSettingsFilePath=$encodedPath"
    [System.IO.File]::WriteAllText("$dest\Settings.ini", $content, [System.Text.UTF8Encoding]::new($false))
}
'@
    $initScriptContent = $initTemplate.Replace('__LICENSE_SERVER__', $LicenseServer)
    [System.IO.File]::WriteAllText($initScriptPath, $initScriptContent, [System.Text.UTF8Encoding]::new($false))

    # Запись в Active Setup (выполняется 1 раз при первом входе каждого нового пользователя)
    $activeSetupKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\RengaConfigurationInit"
    if (-not (Test-Path $activeSetupKey)) {
        New-Item -Path $activeSetupKey -Force | Out-Null
    }
    Set-ItemProperty -Path $activeSetupKey -Name "(Default)" -Value "Renga Professional User Config Initialization"
    Set-ItemProperty -Path $activeSetupKey -Name "Version" -Value "9,2,0,1"
    Set-ItemProperty -Path $activeSetupKey -Name "StubPath" -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$initScriptPath`""
    Write-Log "Active Setup для новых пользователей успешно зарегистрирован."
}

# --- Точка входа скрипта ---
try {
    Write-Log "=========================================================="
    Write-Log "Запуск процесса обновления Renga на компьютере $env:COMPUTERNAME"
    Write-Log "=========================================================="

    # Шаг 1: Завершение процессов
    Stop-RengaProcesses

    # Шаг 2: Удаление предыдущих версий
    Remove-OldRengaVersions

    # Шаг 3: Установка новой версии
    Install-NewRenga

    # Шаг 4: Развертывание настроек и лицензии
    Deploy-Configurations

    Write-Log "=========================================================="
    Write-Log "Все операции успешно выполнены!" "SUCCESS"
    Write-Log "Журнал установки доступен по адресу: $LogFile"
    Write-Log "=========================================================="

    if (-not $Silent) {
        Write-Host "`nНажмите любую клавишу для выхода..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    exit 0
}
catch {
    Write-Log "КРИТИЧЕСКАЯ ОШИБКА: $($_.Exception.Message)" "ERROR"
    Write-Log "Процесс прерван." "ERROR"
    if (-not $Silent) {
        Write-Host "`nНажмите любую клавишу для выхода..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    exit 1
}
