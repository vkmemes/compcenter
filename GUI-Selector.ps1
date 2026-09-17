<#
.SYNOPSIS
    Графический интерфейс (GUI) для выбора аудиторий и запуска развертывания Renga Professional.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$jsonPath = Join-Path $scriptDir "classrooms.json"
$classroomsData = @()
if (Test-Path $jsonPath) {
    $rawJson = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
    $classroomsData = $rawJson | ConvertFrom-Json
}

# Главная форма
$form = New-Object System.Windows.Forms.Form
$form.Text = "Селектор аудиторий для развертывания Renga | ЯГК"
$form.Size = New-Object System.Drawing.Size(720, 680)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

# Верхняя панель заголовка
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 70
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Развертывание Renga Professional"
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(20, 12)
$titleLabel.AutoSize = $true

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Выберите компьютерные аудитории колледжа для автоматического обновления"
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subtitleLabel.Location = New-Object System.Drawing.Point(21, 38)
$subtitleLabel.AutoSize = $true

$headerPanel.Controls.Add($titleLabel)
$headerPanel.Controls.Add($subtitleLabel)
$form.Controls.Add($headerPanel)

# Панель пресетов (быстрого выбора)
$presetPanel = New-Object System.Windows.Forms.Panel
$presetPanel.Location = New-Object System.Drawing.Point(20, 85)
$presetPanel.Size = New-Object System.Drawing.Size(665, 45)

$btnBim = New-Object System.Windows.Forms.Button
$btnBim.Text = "⭐ BIM/Архитектура (~108 ПК)"
$btnBim.Location = New-Object System.Drawing.Point(0, 5)
$btnBim.Size = New-Object System.Drawing.Size(200, 32)
$btnBim.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnBim.ForeColor = [System.Drawing.Color]::White
$btnBim.FlatStyle = "Flat"
$btnBim.FlatAppearance.BorderSize = 0

$btnCorpusB = New-Object System.Windows.Forms.Button
$btnCorpusB.Text = "Корпус Б (160 ПК)"
$btnCorpusB.Location = New-Object System.Drawing.Point(210, 5)
$btnCorpusB.Size = New-Object System.Drawing.Size(140, 32)
$btnCorpusB.BackColor = [System.Drawing.Color]::White
$btnCorpusB.FlatStyle = "Flat"

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = "Выбрать все (293 ПК)"
$btnAll.Location = New-Object System.Drawing.Point(360, 5)
$btnAll.Size = New-Object System.Drawing.Size(150, 32)
$btnAll.BackColor = [System.Drawing.Color]::White
$btnAll.FlatStyle = "Flat"

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "Сбросить"
$btnClear.Location = New-Object System.Drawing.Point(520, 5)
$btnClear.Size = New-Object System.Drawing.Size(95, 32)
$btnClear.BackColor = [System.Drawing.Color]::White
$btnClear.FlatStyle = "Flat"

$presetPanel.Controls.Add($btnBim)
$presetPanel.Controls.Add($btnCorpusB)
$presetPanel.Controls.Add($btnAll)
$presetPanel.Controls.Add($btnClear)
$form.Controls.Add($presetPanel)

# Список аудиторий (CheckedListBox)
$listBox = New-Object System.Windows.Forms.CheckedListBox
$listBox.Location = New-Object System.Drawing.Point(20, 135)
$listBox.Size = New-Object System.Drawing.Size(665, 360)
$listBox.CheckOnClick = $true
$listBox.Font = New-Object System.Drawing.Font("Consolas", 10.5)
$listBox.BackColor = [System.Drawing.Color]::White
$listBox.BorderStyle = "FixedSingle"

# Заполнение списка
foreach ($item in $classroomsData) {
    $display = "{0,-7} | {1,-18} | {2,2} ПК  ({3})" -f $item.Room, $item.Building, $item.Count, $item.Label
    $null = $listBox.Items.Add($display, $false)
}
$form.Controls.Add($listBox)

# Статистика выбора
$statsLabel = New-Object System.Windows.Forms.Label
$statsLabel.Text = "Выбрано: 0 классов | 0 компьютеров"
$statsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
$statsLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$statsLabel.Location = New-Object System.Drawing.Point(20, 508)
$statsLabel.AutoSize = $true
$form.Controls.Add($statsLabel)

# Функция обновления счетчиков
$updateStats = {
    $selCount = 0
    $pcCount = 0
    for ($i = 0; $i -lt $listBox.Items.Count; $i++) {
        if ($listBox.GetItemChecked($i)) {
            $selCount++
            $pcCount += $classroomsData[$i].Count
        }
    }
    $statsLabel.Text = "Выбрано: $selCount классов | $pcCount компьютеров"
    if ($pcCount -gt 0) {
        $statsLabel.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
    } else {
        $statsLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    }
}

$listBox.add_ItemCheck({
    $form.BeginInvoke($updateStats)
})

# Обработчики пресетов
$bimRooms = @("B309", "B308", "B302", "B304", "B305", "B406", "B407")
$btnBim.Add_Click({
    for ($i = 0; $i -lt $classroomsData.Count; $i++) {
        $isBim = $bimRooms -contains $classroomsData[$i].Room
        $listBox.SetItemChecked($i, $isBim)
    }
    &$updateStats
})

$btnCorpusB.Add_Click({
    for ($i = 0; $i -lt $classroomsData.Count; $i++) {
        $isB = $classroomsData[$i].Building -eq "Корпус Б"
        $listBox.SetItemChecked($i, $isB)
    }
    &$updateStats
})

$btnAll.Add_Click({
    for ($i = 0; $i -lt $classroomsData.Count; $i++) {
        $listBox.SetItemChecked($i, $true)
    }
    &$updateStats
})

$btnClear.Add_Click({
    for ($i = 0; $i -lt $classroomsData.Count; $i++) {
        $listBox.SetItemChecked($i, $false)
    }
    &$updateStats
})

# Нижняя панель действий
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "💾 Сохранить в computers.txt"
$btnSave.Location = New-Object System.Drawing.Point(20, 545)
$btnSave.Size = New-Object System.Drawing.Size(210, 42)
$btnSave.BackColor = [System.Drawing.Color]::White
$btnSave.FlatStyle = "Flat"
$btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "🔍 Проверить сеть (Ping)"
$btnCheck.Location = New-Object System.Drawing.Point(240, 545)
$btnCheck.Size = New-Object System.Drawing.Size(180, 42)
$btnCheck.BackColor = [System.Drawing.Color]::White
$btnCheck.FlatStyle = "Flat"

$btnDeploy = New-Object System.Windows.Forms.Button
$btnDeploy.Text = "🚀 ЗАПУСТИТЬ ОБНОВЛЕНИЕ"
$btnDeploy.Location = New-Object System.Drawing.Point(430, 545)
$btnDeploy.Size = New-Object System.Drawing.Size(255, 42)
$btnDeploy.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
$btnDeploy.ForeColor = [System.Drawing.Color]::White
$btnDeploy.FlatStyle = "Flat"
$btnDeploy.FlatAppearance.BorderSize = 0
$btnDeploy.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)

$form.Controls.Add($btnSave)
$form.Controls.Add($btnCheck)
$form.Controls.Add($btnDeploy)

# Функция получения выбранных аудиторий
function Get-SelectedRooms {
    $selected = @()
    for ($i = 0; $i -lt $listBox.Items.Count; $i++) {
        if ($listBox.GetItemChecked($i)) {
            $selected += $classroomsData[$i]
        }
    }
    return $selected
}

# Сохранение в файл
$btnSave.Add_Click({
    $selected = Get-SelectedRooms
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Сначала выберите хотя бы одну аудиторию!", "Внимание", "OK", "Warning") | Out-Null
        return
    }
    $outFile = Join-Path $scriptDir "computers.txt"
    $allHosts = $selected | ForEach-Object { $_.Computers } | Sort-Object
    [System.IO.File]::WriteAllLines($outFile, $allHosts, [System.Text.UTF8Encoding]::new($false))
    [System.Windows.Forms.MessageBox]::Show("Успешно сохранено $($allHosts.Count) компьютеров в файл:`n$outFile", "Готово", "OK", "Information") | Out-Null
})

# Проверка сети
$btnCheck.Add_Click({
    $selected = Get-SelectedRooms
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Сначала выберите хотя бы одну аудиторию!", "Внимание", "OK", "Warning") | Out-Null
        return
    }
    $roomArgs = ($selected | ForEach-Object { "`"$($_.Room)`"" }) -join ", "
    $cmd = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$scriptDir\Scan-DomainComputers.ps1' -Classrooms $roomArgs -CheckOnline; pause`""
    Start-Process powershell.exe -ArgumentList $cmd
})

# Запуск развертывания
$btnDeploy.Add_Click({
    $selected = Get-SelectedRooms
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Сначала выберите хотя бы одну аудиторию!", "Внимание", "OK", "Warning") | Out-Null
        return
    }
    $totalPc = ($selected | Measure-Object -Property Count -Sum).Sum
    $roomNames = ($selected | ForEach-Object { $_.Room }) -join ", "
    
    $confirm = [System.Windows.Forms.MessageBox]::Show("Вы действительно хотите запустить обновление Renga Professional на $totalPc компьютерах в аудиториях ($roomNames)?`n`nБудет открыто окно процесса установки.", "Подтверждение запуска", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        # Сначала обновим computers.txt
        $outFile = Join-Path $scriptDir "computers.txt"
        $allHosts = $selected | ForEach-Object { $_.Computers } | Sort-Object
        [System.IO.File]::WriteAllLines($outFile, $allHosts, [System.Text.UTF8Encoding]::new($false))

        # Запускаем Deploy-RengaRemote.ps1 в новом окне PowerShell с правами администратора
        $deployScript = Join-Path $scriptDir "Deploy-RengaRemote.ps1"
        $cmd = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$deployScript' -ComputerListFile '$outFile' -ThrottleLimit 10; Write-Host '`nНажмите любую клавишу для закрытия...'; `$null = `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')`""
        Start-Process powershell.exe -Verb RunAs -ArgumentList $cmd
    }
})

# По умолчанию активируем BIM-пресет (~108 ПК)
$btnBim.PerformClick()

# Запуск окна
$form.ShowDialog() | Out-Null
$form.Dispose()
