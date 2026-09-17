<#
.SYNOPSIS
    Сканирование домена Active Directory (без необходимости RSAT) для обнаружения
    учебных компьютеров, распределения их по аудиториям/классам и проверки доступности.

.DESCRIPTION
    1. Подключается к домену ygk.ru через встроенный LDAP/ADSI.
    2. Находит все компьютеры в домене, группирует их по учебным аудиториям (B309, B308, B302, A409, F205 и др.) и подразделениям (OU).
    3. Позволяет проверить онлайн-статус компьютеров (Ping, SMB/RPC, WinRM).
    4. Позволяет выгрузить выбранные аудитории или всё подразделение в файл computers.txt для развертывания Renga.

.EXAMPLE
    .\Scan-DomainComputers.ps1

.EXAMPLE
    .\Scan-DomainComputers.ps1 -Classrooms "B309", "B308", "B302", "B304" -Export

.EXAMPLE
    .\Scan-DomainComputers.ps1 -OU "OU=Учебные,OU=Компьютеры,DC=ygk,DC=ru" -Export -CheckOnline
#>

[CmdletBinding()]
param(
    [string[]]$Classrooms,
    [string]$OU,
    [switch]$CheckOnline,
    [switch]$Export,
    [string]$OutputFile = ""
)

if (-not $OutputFile) {
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutputFile = Join-Path $baseDir "computers.txt"
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     Сканирование компьютеров в домене Active Directory   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Поиск всех компьютеров через ADSI (работает без RSAT)
Write-Host "Подключение к домену через LDAP/ADSI..." -ForegroundColor Yellow

$searcher = [adsisearcher]"(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))"
if ($OU) {
    $searcher.SearchRoot = [ADSI]"LDAP://$OU"
}
$searcher.PageSize = 1000
$searcher.PropertiesToLoad.AddRange(@("name", "dnshostname", "distinguishedname", "operatingsystem"))

$adComps = $searcher.FindAll()
Write-Host "Всего активных учетных записей компьютеров в домене: $($adComps.Count)" -ForegroundColor Green

# 2. Обработка и парсинг компьютеров
$allList = foreach ($c in $adComps) {
    $name = [string]$c.Properties.name
    $dns  = [string]$c.Properties.dnshostname
    $os   = [string]$c.Properties.operatingsystem
    $dn   = [string]$c.Properties.distinguishedname
    $ouName = if ($dn -match '^CN=[^,]+,(.*)$') { $matches[1] } else { "" }

    $room = if ($name -match '^([A-Za-z]\d{3})[\-_]') { $matches[1].ToUpper() } else { "ДРУГИЕ" }

    [PSCustomObject]@{
        Name     = $name
        DNS      = if ($dns) { $dns } else { $name }
        Room     = $room
        OU       = $ouName
        OS       = $os
    }
}

# 3. Группировка по аудиториям
$labRooms = $allList | Where-Object { $_.Room -ne "ДРУГИЕ" } | Group-Object Room | Sort-Object Count -Descending

Write-Host "`n--- ОБНАРУЖЕННЫЕ КОМПЬЮТЕРНЫЕ КЛАССЫ И АУДИТОРИИ ---`n" -ForegroundColor Cyan

$summaryTable = foreach ($g in $labRooms) {
    [PSCustomObject]@{
        Аудитория = $g.Name
        КолВоПК   = $g.Count
        Примеры   = ($g.Group.Name | Select-Object -First 4) -join ", "
        OU        = ($g.Group.OU | Select-Object -Unique) -join "; "
    }
}
$summaryTable | Format-Table -AutoSize

# 4. Фильтрация компьютеров по запросу
$selectedComps = @()

if ($Classrooms -and $Classrooms.Count -gt 0) {
    $upperRooms = $Classrooms | ForEach-Object { $_.ToUpper().Trim() }
    $selectedComps = $allList | Where-Object { $upperRooms -contains $_.Room }
    Write-Host "`nВыбрано аудиторий: $($Classrooms -join ', ') (компьютеров: $($selectedComps.Count))" -ForegroundColor Cyan
} elseif ($OU) {
    $selectedComps = $allList
    Write-Host "`nВыбрано подразделение: $OU (компьютеров: $($selectedComps.Count))" -ForegroundColor Cyan
}

# 5. Проверка онлайн-статуса (если запрошен -CheckOnline)
if ($CheckOnline) {
    $targetsToCheck = if ($selectedComps.Count -gt 0) { $selectedComps } else { $allList | Where-Object { $_.Room -ne "ДРУГИЕ" } }
    Write-Host "`nПроверка сетевой доступности для $($targetsToCheck.Count) компьютеров..." -ForegroundColor Yellow

    $onlineCount = 0
    $checkedResults = foreach ($comp in $targetsToCheck) {
        $ping = Test-Connection -ComputerName $comp.Name -Count 1 -Quiet -ErrorAction SilentlyContinue
        $smb = $false
        if ($ping) {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $iar = $tcp.BeginConnect($comp.Name, 445, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(800, $false)) {
                    $tcp.EndConnect($iar)
                    $smb = $true
                }
                $tcp.Close()
            } catch {}
            $onlineCount++
        }
        [PSCustomObject]@{
            Имя   = $comp.Name
            Класс = $comp.Room
            Ping  = if ($ping) { "ONLINE" } else { "OFFLINE" }
            SMB   = if ($smb)  { "OK (Port 445)" } else { "Closed" }
        }
    }

    $checkedResults | Format-Table -AutoSize
    Write-Host "В сети: $onlineCount из $($targetsToCheck.Count)" -ForegroundColor Green
}

# 6. Экспорт в computers.txt
if ($Export -or ($Classrooms -and $Classrooms.Count -gt 0)) {
    if ($selectedComps.Count -gt 0) {
        $linesToExport = $selectedComps | Sort-Object Name | ForEach-Object { $_.DNS }
        Set-Content -Path $OutputFile -Value $linesToExport -Encoding UTF8
        Write-Host "`n[УСПЕХ] Список из $($selectedComps.Count) компьютеров экспортирован в:" -ForegroundColor Green
        Write-Host "  $OutputFile" -ForegroundColor White
    } else {
        Write-Host "`n[ПРЕДУПРЕЖДЕНИЕ] Компьютеры для экспорта не выбраны. Укажите -Classrooms или -OU" -ForegroundColor Yellow
    }
} else {
    Write-Host "`nДля выгрузки компьютеров нужных классов в computers.txt используйте команду:" -ForegroundColor Yellow
    Write-Host '  .\Scan-DomainComputers.ps1 -Classrooms "B309", "B308", "B302", "B304", "B406", "B407" -Export' -ForegroundColor White
}
