# ============================================================
#  PPEPlan — configuração deste PC (corre no fim do PPEPlan-Setup.exe)
#  - Login com a conta Google (só na 1.ª vez, ou com -NovaConta)
#  - Regista "PPEPlan" como remetente de notificações (nome + ícone)
#  - Cria a tarefa agendada "PPEPlan - Agendador" (de 5 em 5 minutos)
#  Pode ser corrido de novo. Horas e ligar/desligar: ⚙ na app PPEPlan.
#  -Silencioso  sem login nem janelas (usado pela atualização automática)
# ============================================================
param([switch]$NovaConta, [switch]$Silencioso)

. (Join-Path $PSScriptRoot 'PPEPlan-Common.ps1')

if (-not $Silencioso) { $Host.UI.RawUI.WindowTitle = 'PPEPlan — configuração' }
Write-Host ''
Write-Host '  PPEPlan — configuração deste PC' -ForegroundColor Red
Write-Host ''

try {
    $config = Get-PPEConfig

    # --- Conta Google ---
    $account = Get-PPEGoogleAccount
    if ($Silencioso) {
        if (-not $account) { throw 'Sem conta Google neste PC.' }
    }
    elseif ($account -and -not $NovaConta) {
        try { Get-PPEAccessToken | Out-Null; Write-Host "  ✔ Conta Google: $($account.Email)" -ForegroundColor Green }
        catch { Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Yellow; $account = $null }
    }
    if (-not $Silencioso -and (-not $account -or $NovaConta)) {
        Write-Host '  Vai abrir o browser: escolhe a tua conta Google (@ppe.pt)' -ForegroundColor Cyan
        Write-Host '  e aceita as permissões (todas as caixas marcadas).'
        Write-Host ''
        $email = Connect-PPEGoogle
        Remove-Item -LiteralPath (Join-Path $script:PPE_StateDir 'data-cache.json') -ErrorAction SilentlyContinue
        Write-Host "  ✔ Conta Google: $email" -ForegroundColor Green
        $account = Get-PPEGoogleAccount
    }

    # --- Remetente das notificações ---
    $icon = Join-Path $script:PPE_StateDir 'icon.png'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'favicon.png') -Destination $icon -Force
    $key = "HKCU:\Software\Classes\AppUserModelId\$($script:PPE_AppId)"
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name DisplayName -Value 'PPEPlan' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name IconUri -Value $icon -PropertyType ExpandString -Force | Out-Null

    # --- Tarefa agendada ---
    # Versões anteriores tinham uma tarefa por email/notificação
    Get-ScheduledTask -TaskName 'PPEPlan - *' -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -ne 'PPEPlan - Agendador' } |
        ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false }

    # conhost --headless evita a janela preta a piscar
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'PPEPlan-Agendador.ps1')`""
    $triggers = @(
        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5)),
        (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME")
    )
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'PPEPlan - Agendador' -Action $action -Trigger $triggers -Settings $settings `
        -Principal $principal -Description 'Emails e notificações do PPEPlan (horas nas Definições da app)' -Force | Out-Null
    Write-Host ''
    Write-Host '  ✔ Tarefa agendada: PPEPlan - Agendador (de 5 em 5 minutos)' -ForegroundColor Green
    if ($Silencioso) { Write-PPELog 'Configurar -Silencioso aplicado'; exit 0 }

    # --- Dados e horários (Definições da app) ---
    Write-Host ''
    $data = $null
    if (Find-PPEDriveFile $script:PPE_DataFileName) {
        Write-Host '  ✔ Tarefas encontradas no Google Drive' -ForegroundColor Green
        $data = Read-PPEData $config
    } else {
        Write-Host "  ! Ainda não há tarefas no Drive: abre o PPEPlan e entra com $($account.Email)." -ForegroundColor Yellow
    }
    $alerts = Get-PPEAlerts $data $config
    $names = @{ emailMorning = 'Email da manhã'; emailEvening = 'Email de fim do dia'; notifyMorning = 'Notificação da manhã'; notifyMidday = 'Notificação do meio-dia'; notifyEndOfDay = 'Notificação de fim do dia' }
    Write-Host ''
    foreach ($s in $alerts.Slots) {
        $status = if (-not $s.On) { 'desligado' } elseif ($s.Kind -eq 'Notify' -and -not $alerts.NotifyOnThisPC) { 'desligada neste PC' } else { $s.Time }
        Write-Host ("  {0,-28} {1}" -f $names[$s.Key], $status)
    }
    $to = if ($alerts.EmailTo) { $alerts.EmailTo } else { $account.Email }
    Write-Host "  Emails para: $to"
    Write-Host '  Para mudar: ⚙ na app PPEPlan → Emails e notificações' -ForegroundColor Cyan

    try { Show-PPEToast -Config $config -Tag 'setup' -Title 'PPEPlan instalado' -Body "Emails e notificações ativos. Horas e ligar/desligar: ⚙ na app PPEPlan." } catch { }

    Write-Host ''
    Write-Host '  Feito.' -ForegroundColor Green
    Start-Sleep -Seconds 8
}
catch {
    Write-PPELog "ERRO Configurar: $($_.Exception.Message)"
    if ($Silencioso) { exit 1 }
    Write-Host ''
    Write-Host "  Falhou: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Para tentar outra vez: menu Iniciar > PPEPlan > Mudar conta Google.'
    Write-Host ''
    Read-Host '  Enter para fechar' | Out-Null
    exit 1
}
