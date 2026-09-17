<#
.SYNOPSIS
    Централизованное удаленное развертывание Renga Professional на 100 компьютерах
    в домене ygk.ru через WMI/SMB или WinRM (без необходимости RSAT).

.DESCRIPTION
    1. Запрашивает компьютеры из Active Directory через встроенный ADSI/LDAP (по OU, классам или из файла).
    2. Проверяет доступность хоста (Ping, SMB/RPC и WinRM).
    3. Автоматически выбирает рабочий транспорт:
       - WinRM (если открыт порт 5985)
       - WMI/RPC + SMB C$ (стандартный доменный доступ, работает на всех машинах колледжа).
    4. Копирует установочный пакет в C:\Windows\Temp\RengaDeploy на целевой ПК.
    5. Запускает Install-Renga.ps1 в тихом режиме и отслеживает завершение процесса.
    6. Удаляет дистрибутив инсталлятора после завершения для освобождения места на диске.
    7. Формирует подробный отчет со статусом и экспортирует в CSV.

.EXAMPLE
    .\Deploy-RengaRemote.ps1 -Classrooms "B309", "B308"

.EXAMPLE
    .\Deploy-RengaRemote.ps1 -TargetOU "OU=Учебные,OU=Компьютеры,DC=ygk,DC=ru"

.EXAMPLE
    .\Deploy-RengaRemote.ps1 -ComputerListFile ".\computers.txt" -ThrottleLimit 10
#>

[CmdletBinding()]
param(
    [string[]]$Classrooms,
    [string]$TargetOU,
    [string]$ComputerListFile,
    [string[]]$ComputerName,
    [int]$ThrottleLimit = 5,
    [string]$LicenseServer = "v-as2.ygk.ru",
    [string]$LogFile = "",
    [string]$CsvReportFile = ""
)

$currentDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $LogFile) { $LogFile = Join-Path $currentDir "Renga_Remote_Deploy.log" }
if (-not $CsvReportFile) { $CsvReportFile = Join-Path $currentDir "Renga_Deployment_Report.csv" }

# Проверка прав администратора
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ИНФО] Локальная сессия без UAC, используются доменные сетевые права администратора." -ForegroundColor Yellow
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-DeployLog {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        "INFO"    { Write-Host $line -ForegroundColor Cyan }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
    }
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

Write-DeployLog "=========================================================="
Write-DeployLog "Запуск скрипта удаленного развертывания Renga Professional"
Write-DeployLog "=========================================================="

# 1. Определение списка компьютеров
$targetComputers = @()

if ($Classrooms -and $Classrooms.Count -gt 0) {
    Write-DeployLog "Поиск компьютеров в аудиториях: $($Classrooms -join ', ') через ADSI..."
    $upperRooms = $Classrooms | ForEach-Object { $_.ToUpper().Trim() }
    
    $searcher = [adsisearcher]"(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))"
    $searcher.PageSize = 1000
    $searcher.PropertiesToLoad.AddRange(@("name", "dnshostname"))
    $allComps = $searcher.FindAll()

    $matched = foreach ($c in $allComps) {
        $name = [string]$c.Properties.name
        if ($name -match '^([A-Za-z]\d{3})[\-_]') {
            $room = $matches[1].ToUpper()
            if ($upperRooms -contains $room) {
                $dns = [string]$c.Properties.dnshostname
                if ($dns) { $dns } else { $name }
            }
        }
    }
    $targetComputers = $matched | Sort-Object -Unique
    Write-DeployLog "Найдено компьютеров в выбранных аудиториях: $($targetComputers.Count)" "SUCCESS"
}
elseif ($TargetOU) {
    Write-DeployLog "Запрос списка компьютеров из Active Directory OU: '$TargetOU'..."
    try {
        $searcher = [adsisearcher]"(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))"
        $searcher.SearchRoot = [ADSI]"LDAP://$TargetOU"
        $searcher.PageSize = 1000
        $searcher.SearchScope = "Subtree"
        $searcher.PropertiesToLoad.AddRange(@("name", "dnshostname"))
        $allComps = $searcher.FindAll()
        $targetComputers = $allComps | ForEach-Object {
            $dns = [string]$_.Properties.dnshostname
            if ($dns) { $dns } else { [string]$_.Properties.name }
        }
        Write-DeployLog "Найдено компьютеров в OU: $($targetComputers.Count)" "SUCCESS"
    } catch {
        Write-DeployLog "Ошибка запроса к Active Directory: $($_.Exception.Message)" "ERROR"
    }
}
elseif ($ComputerName -and $ComputerName.Count -gt 0) {
    $targetComputers = $ComputerName
}
elseif ($ComputerListFile -and (Test-Path $ComputerListFile)) {
    Write-DeployLog "Чтение списка компьютеров из файла: $ComputerListFile"
    $targetComputers = Get-Content -Path $ComputerListFile | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() }
}
elseif (Test-Path (Join-Path $PSScriptRoot "computers.txt")) {
    $defaultFile = Join-Path $PSScriptRoot "computers.txt"
    Write-DeployLog "Чтение списка компьютеров из файла по умолчанию: $defaultFile"
    $targetComputers = Get-Content -Path $defaultFile | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() }
}

if (-not $targetComputers -or $targetComputers.Count -eq 0) {
    Write-DeployLog "Список целевых компьютеров пуст! Укажите -Classrooms, -TargetOU или создайте computers.txt" "ERROR"
    Write-Host "`nПримеры использования:" -ForegroundColor Yellow
    Write-Host '  .\Deploy-RengaRemote.ps1 -Classrooms "B309", "B308", "B302"' -ForegroundColor Gray
    Write-Host '  .\Deploy-RengaRemote.ps1 -TargetOU "OU=Учебные,OU=Компьютеры,DC=ygk,DC=ru"' -ForegroundColor Gray
    Write-Host '  .\Deploy-RengaRemote.ps1 -ComputerListFile ".\computers.txt"' -ForegroundColor Gray
    exit 1
}

Write-DeployLog "Всего компьютеров для обработки: $($targetComputers.Count)"

# Проверка наличия исходных файлов на локальной машине
$sourceDir = $PSScriptRoot
$setupExe = Join-Path $sourceDir "RengaProfessionalSetup.exe"
$installPs1 = Join-Path $sourceDir "Install-Renga.ps1"
$configDir = Join-Path $sourceDir "Renga Software"

if (-not (Test-Path $setupExe) -or -not (Test-Path $installPs1) -or -not (Test-Path $configDir)) {
    Write-DeployLog "ОШИБКА: В папке $sourceDir отсутствуют необходимые файлы (RengaProfessionalSetup.exe, Install-Renga.ps1 или папка Renga Software)!" "ERROR"
    exit 1
}

Write-DeployLog "Начало развертывания (параллельных потоков: $ThrottleLimit)..."

# Запуск параллельной обработки компьютеров через пул заданий Start-Job
$jobs = @()
$counter = 0

foreach ($computer in $targetComputers) {
    while ((Get-Job -State Running).Count -ge $ThrottleLimit) {
        Start-Sleep -Milliseconds 500
    }

    $counter++
    Write-DeployLog "[$counter/$($targetComputers.Count)] Запуск задачи для $computer..."

    $job = Start-Job -ScriptBlock {
        param($comp, $srcDir, $licServer)

        $compResult = [PSCustomObject]@{
            ComputerName = $comp
            Status       = "Pending"
            Transport    = "None"
            Message      = ""
            Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }

        # 1. Проверка доступности хоста по сети (Ping)
        $isPing = Test-Connection -ComputerName $comp -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $isPing) {
            $compResult.Status = "Offline"
            $compResult.Message = "Компьютер выключен или недоступен по сети (нет ответа на Ping)"
            return $compResult
        }

        # 2. Проверка доступности SMB C$
        $remoteTemp = "\\$comp\c$\Windows\Temp\RengaDeploy"
        try {
            if (-not (Test-Path $remoteTemp)) {
                New-Item -ItemType Directory -Path $remoteTemp -Force | Out-Null
            }
        } catch {
            $compResult.Status = "Failed"
            $compResult.Message = "Нет доступа к административной сетевой папке \\$comp\c`$: $($_.Exception.Message)"
            return $compResult
        }

        # 3. Копирование установочных файлов (с проверкой размера)
        try {
            $remoteSetup = Join-Path $remoteTemp "RengaProfessionalSetup.exe"
            $localSetup = Join-Path $srcDir "RengaProfessionalSetup.exe"

            $needCopy = $true
            if (Test-Path $remoteSetup) {
                $localSize = (Get-Item $localSetup).Length
                $remoteSize = (Get-Item $remoteSetup).Length
                if ($localSize -eq $remoteSize) {
                    $needCopy = $false
                }
            }

            if ($needCopy) {
                Copy-Item -Path $localSetup -Destination $remoteTemp -Force
            }
            Copy-Item -Path (Join-Path $srcDir "Install-Renga.ps1") -Destination $remoteTemp -Force
            Copy-Item -Path (Join-Path $srcDir "Renga Software") -Destination $remoteTemp -Recurse -Force
        } catch {
            $compResult.Status = "Failed"
            $compResult.Message = "Ошибка при копировании файлов: $($_.Exception.Message)"
            return $compResult
        }

        # 4. Проверка транспорта удаленного запуска: WinRM или WMI
        $hasWinRM = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($comp, 5985, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) {
                $tcp.EndConnect($iar)
                $hasWinRM = $true
            }
            $tcp.Close()
        } catch {}

        # 5. Выполнение установки
        if ($hasWinRM) {
            # Вариант А: WinRM
            $compResult.Transport = "WinRM"
            try {
                $session = New-PSSession -ComputerName $comp -ErrorAction Stop
                $remoteScript = "C:\Windows\Temp\RengaDeploy\Install-Renga.ps1"
                $remoteOutput = Invoke-Command -Session $session -ScriptBlock {
                    param($scriptPath, $lic)
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Silent -LicenseServer $lic
                    return $LASTEXITCODE
                } -ArgumentList $remoteScript, $licServer
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue

                if ($remoteOutput -eq 0 -or $remoteOutput -eq 3010) {
                    $compResult.Status = "Success"
                    $compResult.Message = "Успешно установлено через WinRM"
                } else {
                    $compResult.Status = "Failed"
                    $compResult.Message = "Скрипт завершился с кодом $remoteOutput"
                }
            } catch {
                $compResult.Status = "Failed"
                $compResult.Message = "Ошибка WinRM: $($_.Exception.Message)"
            }
        } else {
            # Вариант Б: WMI Win32_Process (стандартный удаленный запуск в домене)
            $compResult.Transport = "WMI"
            try {
                $wmi = [wmiclass]"\\$comp\root\cimv2:Win32_Process"
                $cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\RengaDeploy\Install-Renga.ps1 -Silent -LicenseServer $licServer"
                $procRes = $wmi.Create($cmdLine)

                if ($procRes.ReturnValue -ne 0) {
                    $compResult.Status = "Failed"
                    $compResult.Message = "WMI Create Process вернул ошибку код $($procRes.ReturnValue)"
                    return $compResult
                }

                $pidToWatch = $procRes.ProcessId
                # Ожидание завершения процесса (максимум 15 минут)
                $maxWaitSec = 900
                $elapsed = 0
                while ($elapsed -lt $maxWaitSec) {
                    Start-Sleep -Seconds 5
                    $elapsed += 5
                    $procActive = Get-WmiObject -Class Win32_Process -ComputerName $comp -Filter "ProcessId = $pidToWatch" -ErrorAction SilentlyContinue
                    if (-not $procActive) {
                        break
                    }
                }

                # Проверяем результат по лог-файлу установки на удаленной машине
                $remoteLogFile = "\\$comp\c$\Windows\Temp\Renga_Deploy.log"
                if (Test-Path $remoteLogFile) {
                    $logContent = Get-Content -Path $remoteLogFile -Tail 20 -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($logContent -match "Все операции успешно выполнены!") {
                        $compResult.Status = "Success"
                        $compResult.Message = "Успешно установлено через WMI"
                    } elseif ($logContent -match "КРИТИЧЕСКАЯ ОШИБКА") {
                        $compResult.Status = "Failed"
                        $compResult.Message = "Ошибка в логе установки: $(($logContent | Where-Object { $_ -match 'КРИТИЧЕСКАЯ ОШИБКА' }) -join ' ')"
                    } else {
                        $compResult.Status = "Success"
                        $compResult.Message = "Процесс установки завершен"
                    }
                } else {
                    $compResult.Status = "Success"
                    $compResult.Message = "Процесс завершен (лог не обнаружен)"
                }
            } catch {
                $compResult.Status = "Failed"
                $compResult.Message = "Ошибка WMI: $($_.Exception.Message)"
            }
        }

        # 6. Очистка объемного установочного файла на удаленном ПК
        try {
            $remoteSetup = Join-Path $remoteTemp "RengaProfessionalSetup.exe"
            if (Test-Path $remoteSetup) {
                Remove-Item -Path $remoteSetup -Force -ErrorAction SilentlyContinue
            }
        } catch {}

        return $compResult
    } -ArgumentList $computer, $sourceDir, $LicenseServer

    $jobs += $job
}

# Ожидание завершения всех заданий
Write-DeployLog "Ожидание завершения всех удаленных задач..."
$allResults = @()
foreach ($j in $jobs) {
    $res = Receive-Job -Job $j -Wait
    if ($res) {
        $allResults += $res
        $statusLevel = switch ($res.Status) {
            "Success" { "SUCCESS" }
            "Offline" { "WARN" }
            default   { "ERROR" }
        }
        Write-DeployLog "[$($res.ComputerName)] [$($res.Transport)] $($res.Status): $($res.Message)" $statusLevel
    }
    Remove-Job -Job $j -Force
}

# Экспорт отчета в CSV
try {
    $allResults | Export-Csv -Path $CsvReportFile -NoTypeInformation -Encoding UTF8
    Write-DeployLog "Сводный отчет сохранен в CSV: $CsvReportFile" "SUCCESS"
} catch {
    Write-DeployLog "Не удалось записать CSV отчет: $($_.Exception.Message)" "WARN"
}

# Вывод сводки в консоль
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "                   ИТОГОВАЯ СВОДКА" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
$successCount = ($allResults | Where-Object { $_.Status -eq "Success" }).Count
$offlineCount = ($allResults | Where-Object { $_.Status -eq "Offline" }).Count
$failedCount = ($allResults | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host "Всего ПК:          $($allResults.Count)" -ForegroundColor White
Write-Host "Успешно:           $successCount" -ForegroundColor Green
Write-Host "Недоступно:        $offlineCount" -ForegroundColor Yellow
Write-Host "Ошибок установки:  $failedCount" -ForegroundColor Red
Write-Host "==========================================================`n" -ForegroundColor Cyan
