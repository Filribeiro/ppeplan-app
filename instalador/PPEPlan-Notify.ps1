# ============================================================
#  PPEPlan — notificações Windows
#  -Slot Morning   Bom dia: tarefas de hoje + alerta de prazos
#  -Slot Midday    Ponto de situação: o que falta hoje
#  -Slot EndOfDay  Fim do dia: marcar concluídas
#  -Force          Ignora horário, fim de semana e "já mostrado hoje"
#  Chamado pelo PPEPlan-Agendador.ps1; horas nas Definições da app.
# ============================================================
param(
    [ValidateSet('Morning', 'Midday', 'EndOfDay')] [string]$Slot = 'Morning',
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'PPEPlan-Common.ps1')

try {
    $config = Get-PPEConfig
    $n = $config.notifications
    $now = Get-Date
    $stateKey = "toast$Slot"
    $todayKey = $now.ToString('yyyy-MM-dd')

    $data = Read-PPEData $config
    if (-not $Force) {
        $alerts = Get-PPEAlerts $data $config
        if (-not (Test-PPESlotDue $alerts (Get-PPEAlertSlot $alerts 'Notify' $Slot) $data $config $now)) { return }
    }
    $plan = Get-PPEPlan -Data $data -Config $config

    $max = [int]$n.maxTasksListed
    $bullets = {
        param($list)
        $lines = @($list | Select-Object -First $max | ForEach-Object {
            $d = $_.DaysToDeadline
            $flag = if ($null -eq $d) { '' } elseif ($d -lt 0) { ' ⚠' } elseif ($d -eq 0) { ' ⏰' } else { '' }
            '• {0} ({1}){2}' -f $_.Task.title, (Format-PPEHours $_.HoursToday), $flag
        })
        if ($list.Count -gt $max) { $lines += "+ $($list.Count - $max) mais" }
        $lines -join "`n"
    }

    $attribution = ''
    if ($plan.SavedAt -and ($now - $plan.SavedAt).TotalDays -gt [double]$config.staleDataWarningDays) {
        $attribution = 'Dados de ' + (Format-PPEDay $plan.SavedAt 'd MMM') + ' — abre a app para sincronizar'
    }

    $hours = ($plan.MyToday | Measure-Object -Property HoursToday -Sum).Sum
    $count = $plan.MyToday.Count

    switch ($Slot) {
        'Morning' {
            if ($count -eq 0) {
                Show-PPEToast -Config $config -Tag 'morning' -Attribution $attribution `
                    -Title 'Bom dia — sem tarefas agendadas para hoje' -Body 'Aproveita para planear no PPEPlan.'
            } else {
                $label = if ($count -eq 1) { 'tarefa' } else { 'tarefas' }
                Show-PPEToast -Config $config -Tag 'morning' -Attribution $attribution `
                    -Title "Bom dia — $count $label para hoje ($(Format-PPEHours $hours))" -Body (& $bullets $plan.MyToday)
            }

            $critical = @($plan.Overdue) + @($plan.DueToday)
            if ($critical.Count -gt 0) {
                $parts = @()
                if ($plan.Overdue.Count -gt 0)  { $parts += "$($plan.Overdue.Count) em atraso" }
                if ($plan.DueToday.Count -gt 0) { $parts += "$($plan.DueToday.Count) com prazo hoje" }
                $body = @($critical | Select-Object -First $max | ForEach-Object { '• {0} — {1}' -f $_.Task.title, (Get-PPEDeadlineLabel $_) })
                if ($critical.Count -gt $max) { $body += "+ $($critical.Count - $max) mais" }
                Show-PPEToast -Config $config -Tag 'deadlines' -Reminder `
                    -Title ('Prazos: ' + ($parts -join ' · ')) -Body ($body -join "`n")
            }
        }
        'Midday' {
            if ($count -eq 0 -and $plan.CompletedToday.Count -eq 0) { break }
            if ($count -eq 0) {
                Show-PPEToast -Config $config -Tag 'midday' -Title 'Tudo feito para hoje' `
                    -Body "Concluíste $($plan.CompletedToday.Count) tarefa(s). Bom trabalho!"
            } else {
                $done = if ($plan.CompletedToday.Count -gt 0) { " · $($plan.CompletedToday.Count) concluída(s)" } else { '' }
                Show-PPEToast -Config $config -Tag 'midday' -Attribution $attribution `
                    -Title "Ponto de situação — $(Format-PPEHours $hours) para o resto do dia$done" -Body (& $bullets $plan.MyToday)
            }
        }
        'EndOfDay' {
            if ($count -eq 0 -and $plan.CompletedToday.Count -eq 0) { break }
            $done = $plan.CompletedToday.Count
            $title = if ($done -gt 0) { "Fim do dia — $done concluída(s) hoje" } else { 'Fim do dia — nada marcado como concluído' }
            $body = if ($count -gt 0) { "Marca no PPEPlan o que ficou feito:`n" + (& $bullets $plan.MyToday) } else { 'Plano de hoje cumprido.' }
            Show-PPEToast -Config $config -Tag 'endofday' -Attribution $attribution -Title $title -Body $body
        }
    }

    if (-not $Force) { Set-PPEStateValue $stateKey $todayKey }
    Write-PPELog "Notify $Slot mostrada ($count tarefas hoje)"
}
catch {
    Write-PPELog "ERRO Notify ${Slot}: $($_.Exception.Message)"
    throw
}
