# ============================================================
#  PPEPlan — emails diários
#  -Slot Morning  Tarefas de hoje
#  -Slot Evening  Resumo do dia + plano do próximo dia útil
#  (horas e ligar/desligar: Definições da app; chamado pelo PPEPlan-Agendador.ps1)
#  -Preview  Gera o HTML em %LOCALAPPDATA%\PPEPlan\email-preview.html e abre-o
#            e mostra o texto da notificação do telemóvel (não envia nada)
#  -Force    Envia mesmo que já tenha sido enviado hoje / fim de semana / fora de horas
#            (conta como o email desse dia: o envio automático já não repete)
#  -Canal    Com -Force: Ambos (defeito), Email ou Push (Push só testa o telemóvel
#            e não conta como o email do dia)
#
#  Envia pela Gmail API com a conta Google do PC e, para os telemóveis com as
#  notificações ativas na app, por Web Push (PPEPlan-Push.ps1). Com vários PCs
#  na mesma conta, o registo de envio fica no Drive (ppeplan-emails-enviados.json)
#  para só um deles enviar.
# ============================================================
param(
    [ValidateSet('Morning', 'Evening')] [string]$Slot = 'Morning',
    [switch]$Preview,
    [switch]$Force,
    [ValidateSet('Ambos', 'Email', 'Push')] [string]$Canal = 'Ambos'
)

. (Join-Path $PSScriptRoot 'PPEPlan-Common.ps1')
# Se o push não carregar (ex.: compilação falhar), o email continua a sair
try { . (Join-Path $PSScriptRoot 'PPEPlan-Push.ps1') }
catch {
    Write-PPELog "ERRO a carregar PPEPlan-Push.ps1: $($_.Exception.Message)"
    function Send-PPEPush { throw 'PPEPlan-Push.ps1 não carregou (ver log)' }
}

$script:PPE_AgendaSemPermissao = 'Agenda não incluída: este PC ainda não tem acesso ao Calendário Google. No PC: menu Iniciar → PPEPlan → Mudar conta Google.'

function New-PPEEmailHtml {
    param($Plan, $Config, [string]$Slot = 'Morning', $NextPlan, $Agenda)

    $h = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $red = '#C73943'; $text = '#1B1F2A'; $muted = '#5B6770'; $border = '#E4E7EB'; $green = '#4F7A4E'
    $sb = New-Object System.Text.StringBuilder
    $cap = { param($s) $s.Substring(0, 1).ToUpper() + $s.Substring(1) }

    $badge = {
        param($label, $fg, $bg)
        "<span style=`"display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700;color:$fg;background:$bg`">$(& $h $label)</span>"
    }
    $deadlineBadge = {
        param($it)
        $label = Get-PPEDeadlineLabel $it
        $d = $it.DaysToDeadline
        if ($null -ne $d -and $d -lt 0)         { & $badge $label '#A02530' '#FCE4E6' }
        elseif ($d -eq 0 -or $it.Risk -ne 'ok') { & $badge $label '#8A6320' '#F5E6BD' }
        else                                     { & $badge $label '#4F7A4E' '#DCE8DB' }
    }
    $section = {
        param($title)
        [void]$sb.Append("<tr><td style=`"padding:22px 24px 8px;font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:$muted`">$(& $h $title)</td></tr>")
    }
    $row = {
        param($html)
        [void]$sb.Append("<tr><td style=`"padding:4px 24px;font-size:14px`">$html</td></tr>")
    }

    # Cartões de tarefa (título, horas no dia, prazo, descrição, subtarefas)
    $cards = {
        param($p, [string]$dayWord, [string]$emptyText)
        if ($p.MyToday.Count -eq 0) {
            [void]$sb.Append("<tr><td style=`"padding:4px 24px 8px;color:$muted;font-size:14px`">$(& $h $emptyText)</td></tr>")
        }
        $n = 0
        foreach ($it in $p.MyToday) {
            $n++
            $t = $it.Task
            $meta = "<b>$(Format-PPEHours $it.HoursToday) $dayWord</b>"
            if ([double]$t.estimatedHours -gt $it.HoursToday) { $meta += " <span style=`"color:$muted`">de $(Format-PPEHours ([double]$t.estimatedHours))</span>" }
            $meta += ' &nbsp;' + (& $deadlineBadge $it)
            if ($t.status -eq 'in_progress') { $meta += ' ' + (& $badge 'Em curso' '#3D4A99' '#E0E4FA') }
            if ($it.End -and $it.End -ne $p.Today.ToString('yyyy-MM-dd')) {
                $meta += " <span style=`"color:$muted;font-size:12px`">· termina $(& $h (Format-PPEDay (ConvertFrom-IsoDay $it.End) 'ddd d MMM'))</span>"
            }
            [void]$sb.Append("<tr><td style=`"padding:6px 24px`"><table role=`"presentation`" width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" style=`"border:1px solid $border;border-left:4px solid $red;border-radius:6px`"><tr><td style=`"padding:12px 14px`">")
            [void]$sb.Append("<div style=`"font-size:15px;font-weight:700`">$n. $(& $h $t.title)</div>")
            [void]$sb.Append("<div style=`"font-size:13px;margin-top:6px`">$meta</div>")
            if ($t.description) {
                $desc = (& $h $t.description) -replace "`r?`n", '<br>'
                [void]$sb.Append("<div style=`"font-size:13px;color:$muted;margin-top:8px`">$desc</div>")
            }
            if ($it.PendingSubtasks.Count -gt 0) {
                [void]$sb.Append("<div style=`"font-size:13px;margin-top:8px`">")
                foreach ($st in $it.PendingSubtasks) {
                    $who = if ($st.assignee) { " <span style=`"color:$muted`">($(& $h $st.assignee))</span>" } else { '' }
                    [void]$sb.Append("☐ $(& $h $st.title) <span style=`"color:$muted`">· $(Format-PPEHours ([double]$st.estimatedHours))</span>$who<br>")
                }
                [void]$sb.Append('</div>')
            }
            [void]$sb.Append('</td></tr></table></td></tr>')
        }
    }

    # Prazos atrasados/próximos que não estão nos cartões
    $deadlines = {
        param($p)
        $ids = @($p.MyToday | ForEach-Object { $_.Task.id })
        $list = @($p.Ordered | Where-Object {
            $_.IsMine -and $ids -notcontains $_.Task.id -and $null -ne $_.DaysToDeadline -and $_.DaysToDeadline -le [int]$Config.email.upcomingDays
        } | Sort-Object DaysToDeadline)
        if ($list.Count -eq 0) { return }
        $hasOverdue = @($list | Where-Object { $_.DaysToDeadline -lt 0 }).Count -gt 0
        & $section $(if ($hasOverdue) { "Em atraso e prazos nos próximos $($Config.email.upcomingDays) dias" } else { "Prazos nos próximos $($Config.email.upcomingDays) dias" })
        foreach ($it in $list) {
            $start = if ($it.Start) { "começa $(Format-PPEDay (ConvertFrom-IsoDay $it.Start) 'ddd d MMM')" } else { '' }
            & $row "$(& $deadlineBadge $it) &nbsp;$(& $h $it.Task.title) <span style=`"color:$muted;font-size:12px`">· $(Format-PPEHours ([double]$it.Task.estimatedHours)) $(& $h $start)</span>"
        }
    }

    $delegated = {
        param($p, [string]$title)
        if (-not $Config.email.includeDelegated -or $p.Delegated.Count -eq 0) { return }
        & $section $title
        foreach ($g in ($p.Delegated | Group-Object Assignee | Sort-Object Name)) {
            $list = ($g.Group | ForEach-Object { "$(& $h $_.Task.title) <span style=`"color:$muted`">($(Format-PPEHours $_.HoursToday))</span>" }) -join '<br>'
            & $row "<b>$(& $h $g.Name)</b><br>$list"
        }
    }

    # Eventos dos calendários escolhidos nas Definições (Get-PPEAgenda)
    $agendaSection = {
        param([DateTime]$day, [string]$heading)
        if (-not $Agenda -or -not $Agenda.Configured) { return }
        & $section $heading
        if ($Agenda.Problem -eq 'sem-permissao') {
            [void]$sb.Append("<tr><td style=`"padding:4px 24px 8px;color:#6B4A10;font-size:13px`">$(& $h $script:PPE_AgendaSemPermissao)</td></tr>")
            return
        }
        if ($Agenda.Events.Count -eq 0) {
            [void]$sb.Append("<tr><td style=`"padding:4px 24px 8px;color:$muted;font-size:14px`">Sem eventos.</td></tr>")
        }
        foreach ($ev in $Agenda.Events) {
            $extra = @($ev.Where, $ev.Calendar) | Where-Object { $_ }
            $name = if ($ev.Link) { "<a href=`"$(& $h $ev.Link)`" style=`"color:$text;text-decoration:none`">$(& $h $ev.Title)</a>" } else { & $h $ev.Title }
            [void]$sb.Append("<tr><td style=`"padding:4px 24px;font-size:14px`"><table role=`"presentation`" cellpadding=`"0`" cellspacing=`"0`"><tr>" +
                "<td style=`"width:96px;vertical-align:top;font-weight:700;white-space:nowrap`">$(& $h (Format-PPEEventTime $ev $day))</td>" +
                "<td style=`"vertical-align:top`">$name" +
                $(if ($extra) { "<div style=`"font-size:12px;color:$muted`">$(& $h ($extra -join ' · '))</div>" } else { '' }) +
                '</td></tr></table></td></tr>')
        }
        if ($Agenda.Problem) {
            [void]$sb.Append("<tr><td style=`"padding:4px 24px;font-size:12px;color:$muted`">Agenda incompleta: $(& $h $Agenda.Problem)</td></tr>")
        }
    }

    $hoursOf = { param($p) [double](($p.MyToday | Measure-Object -Property HoursToday -Sum).Sum) }
    $tasksLabel = { param($c, $hrs) if ($c -eq 0) { 'sem tarefas' } elseif ($c -eq 1) { "1 tarefa · $(Format-PPEHours $hrs)" } else { "$c tarefas · $(Format-PPEHours $hrs)" } }
    $todayLabel = & $cap $Plan.Today.ToString("dddd, d 'de' MMMM", $script:PT)
    $eventsLabel = ''
    if ($Agenda -and $Agenda.Configured -and -not $Agenda.Problem -and $Agenda.Events.Count -gt 0) {
        $eventsLabel = if ($Agenda.Events.Count -eq 1) { ' · 1 evento' } else { " · $($Agenda.Events.Count) eventos" }
    }

    if ($Slot -eq 'Evening') {
        $done = @($Plan.CompletedToday)
        $nextLabel = $NextPlan.Today.ToString("dddd, d MMM", $script:PT)
        $kicker = 'PPEPlan · fim do dia'
        $headline = $todayLabel
        $summary = "$($done.Count) concluída(s) hoje · ${nextLabel}: $(& $tasksLabel $NextPlan.MyToday.Count (& $hoursOf $NextPlan))$eventsLabel"
        $subject = "PPEPlan · Fim do dia $(Format-PPEDay $Plan.Today 'ddd, d MMM') · $($done.Count) concluída(s) · amanhã $(& $tasksLabel $NextPlan.MyToday.Count (& $hoursOf $NextPlan))$eventsLabel"
    } else {
        $kicker = 'PPEPlan'
        $headline = $todayLabel
        $summary = (& $cap (& $tasksLabel $Plan.MyToday.Count (& $hoursOf $Plan))) + $eventsLabel
        $subject = "PPEPlan · $(Format-PPEDay $Plan.Today 'ddd, d MMM') · $summary"
    }

    [void]$sb.Append(@"
<!doctype html><html><body style="margin:0;padding:0;background:#EEF0F3;font-family:Segoe UI,Arial,sans-serif;color:$text">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EEF0F3;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;background:#FFFFFF;border-radius:10px;overflow:hidden">
<tr><td style="background:$red;padding:20px 24px;color:#FFFFFF">
  <div style="font-size:13px;opacity:.85">$(& $h $kicker)</div>
  <div style="font-size:22px;font-weight:700;margin-top:2px">$(& $h $headline)</div>
  <div style="font-size:14px;margin-top:4px">$(& $h $summary)</div>
</td></tr>
"@)

    if ($Plan.SavedAt -and ((Get-Date) - $Plan.SavedAt).TotalDays -gt [double]$Config.staleDataWarningDays) {
        [void]$sb.Append("<tr><td style=`"padding:12px 24px;background:#F5E6BD;color:#6B4A10;font-size:13px`">⚠ Os dados foram guardados pela última vez a <b>$(& $h (Format-PPEDay $Plan.SavedAt 'd MMM yyyy, HH:mm'))</b>. Abre o PPEPlan para sincronizar — este plano pode estar desatualizado.</td></tr>")
    }

    if ($Slot -eq 'Evening') {
        & $section 'Concluídas hoje'
        if ($done.Count -eq 0) {
            [void]$sb.Append("<tr><td style=`"padding:4px 24px 8px;color:$muted;font-size:14px`">Nenhuma tarefa marcada como concluída hoje.</td></tr>")
        }
        foreach ($t in $done) { & $row "<span style=`"color:$green;font-weight:700`">✓</span> $(& $h $t.title)" }

        if ($Plan.MyToday.Count -gt 0) {
            & $section 'Ainda em aberto do plano de hoje'
            foreach ($it in $Plan.MyToday) {
                & $row "$(& $deadlineBadge $it) &nbsp;$(& $h $it.Task.title) <span style=`"color:$muted;font-size:12px`">· $(Format-PPEHours $it.HoursToday) previstas hoje</span>"
            }
            [void]$sb.Append("<tr><td style=`"padding:4px 24px;font-size:12px;color:$muted`">Se já estão feitas, marca-as no PPEPlan para o plano de amanhã ficar certo.</td></tr>")
        }

        & $agendaSection $NextPlan.Today ('Agenda de amanhã · ' + $nextLabel)
        & $section ('Amanhã · ' + $nextLabel)
        & $cards $NextPlan 'previstas' 'Nada agendado para o próximo dia útil.'
        & $deadlines $NextPlan
        & $delegated $NextPlan 'Delegadas com trabalho amanhã'
    } else {
        & $agendaSection $Plan.Today 'Agenda de hoje'
        & $section 'Para hoje'
        & $cards $Plan 'hoje' 'Nada agendado para hoje.'
        & $deadlines $Plan
        & $delegated $Plan 'Delegadas com trabalho hoje'
    }

    $saved = if ($Plan.SavedAt) { ' · dados guardados a ' + (Format-PPEDay $Plan.SavedAt 'd MMM, HH:mm') } else { '' }
    $link = if ($Config.appUrl -and $Config.appUrl -match '^https?:') { " · <a href=`"$(& $h $Config.appUrl)`" style=`"color:$red`">Abrir PPEPlan</a>" } else { '' }
    [void]$sb.Append("<tr><td style=`"padding:22px 24px;font-size:12px;color:#8B95A0;border-top:1px solid $border`">Gerado automaticamente pelo PPEPlan$(& $h $saved)$link</td></tr>")
    [void]$sb.Append('</table></td></tr></table></body></html>')

    [pscustomobject]@{ Subject = $subject; Html = $sb.ToString() }
}

# O mesmo conteúdo do email, em texto, para a notificação do telemóvel
# (o Android mostra o título e, ao expandir, o texto todo)
function New-PPEPushText {
    param($Plan, $Config, [string]$Slot = 'Morning', $NextPlan, $Agenda)

    $lines = New-Object System.Collections.Generic.List[string]
    $hoursOf = { param($p) [double](($p.MyToday | Measure-Object -Property HoursToday -Sum).Sum) }
    $tasksLabel = { param($p) $c = $p.MyToday.Count; if ($c -eq 0) { 'sem tarefas' } elseif ($c -eq 1) { "1 tarefa (" + (Format-PPEHours (& $hoursOf $p)) + ')' } else { "$c tarefas (" + (Format-PPEHours (& $hoursOf $p)) + ')' } }
    $block = {
        param([string]$heading, $items)
        $items = @($items | Where-Object { $_ })
        if ($items.Count -eq 0) { return }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add($heading)
        foreach ($i in $items) { $lines.Add($i) }
    }
    $agendaLines = {
        param([DateTime]$day, [string]$heading)
        if (-not $Agenda -or -not $Agenda.Configured) { return }
        if ($Agenda.Problem -eq 'sem-permissao') { & $block $heading @($script:PPE_AgendaSemPermissao); return }
        $items = @($Agenda.Events | ForEach-Object { "$(Format-PPEEventTime $_ $day)  $($_.Title)" })
        if ($items.Count -eq 0) { $items = @('Sem eventos') }
        & $block $heading $items
    }
    $taskLines = {
        param($p)
        $n = 0
        @($p.MyToday | ForEach-Object {
            $n++
            $dl = Get-PPEDeadlineLabel $_
            $flag = if ($null -ne $_.DaysToDeadline -and $_.DaysToDeadline -lt 0) { ' ⚠' } else { '' }
            "$n. $($_.Task.title) · $(Format-PPEHours $_.HoursToday) · $dl$flag"
        })
    }
    $deadlineLines = {
        param($p)
        $ids = @($p.MyToday | ForEach-Object { $_.Task.id })
        @($p.Ordered | Where-Object {
            $_.IsMine -and $ids -notcontains $_.Task.id -and $null -ne $_.DaysToDeadline -and $_.DaysToDeadline -le [int]$Config.email.upcomingDays
        } | Sort-Object DaysToDeadline | ForEach-Object { "$(Get-PPEDeadlineLabel $_) · $($_.Task.title)" })
    }
    $delegatedLines = {
        param($p)
        if (-not $Config.email.includeDelegated) { return @() }
        @($p.Delegated | Group-Object Assignee | Sort-Object Name | ForEach-Object {
            "$($_.Name): " + (($_.Group | ForEach-Object { $_.Task.title }) -join ', ')
        })
    }

    if ($Plan.SavedAt -and ((Get-Date) - $Plan.SavedAt).TotalDays -gt [double]$Config.staleDataWarningDays) {
        $lines.Add("⚠ Dados de $(Format-PPEDay $Plan.SavedAt 'd MMM') — abre o PPEPlan para sincronizar")
    }

    $events = if ($Agenda -and $Agenda.Configured -and -not $Agenda.Problem) { $Agenda.Events.Count } else { 0 }
    $eventsLabel = if ($events -eq 1) { ' · 1 evento' } elseif ($events -gt 1) { " · $events eventos" } else { '' }

    if ($Slot -eq 'Evening') {
        $done = @($Plan.CompletedToday)
        $title = "Fim do dia: $($done.Count) concluída(s) · amanhã $(& $tasksLabel $NextPlan)$eventsLabel"
        & $block "✓ Concluídas hoje" @($done | ForEach-Object { "✓ $($_.title)" })
        & $block 'Ainda em aberto hoje' @($Plan.MyToday | ForEach-Object { "• $($_.Task.title)" })
        $nextLabel = Format-PPEDay $NextPlan.Today 'ddd, d MMM'
        & $agendaLines $NextPlan.Today "📅 Agenda de amanhã ($nextLabel)"
        & $block "Tarefas de amanhã" (& $taskLines $NextPlan)
        & $block 'Prazos' (& $deadlineLines $NextPlan)
        & $block 'Delegadas' (& $delegatedLines $NextPlan)
    } else {
        $title = "Hoje: $(& $tasksLabel $Plan)$eventsLabel"
        & $agendaLines $Plan.Today '📅 Agenda'
        & $block 'Tarefas' (& $taskLines $Plan)
        & $block 'Prazos' (& $deadlineLines $Plan)
        & $block 'Delegadas' (& $delegatedLines $Plan)
    }
    if ($lines.Count -eq 0) { $lines.Add('Nada agendado.') }
    [pscustomobject]@{ Title = $title; Body = ($lines -join "`n"); Tag = "resumo-$($Slot.ToLower())" }
}

function Send-PPEEmail($Mail, $Alerts) {
    # Sem destinatário nas Definições da app: a própria conta Google
    $to = if ($Alerts.EmailTo) { $Alerts.EmailTo } else { (Get-PPEGoogleAccount).Email }
    Send-PPEGmail -To $to -Subject $Mail.Subject -Html $Mail.Html
}

# ---------- Registo partilhado da conta (ppeplan-emails-enviados.json no Drive) ----------
#   { "emailSent": "2026-09-15", "emailSentBy": "PC-CASA",
#     "reservaMorning": { "dia": "2026-09-15", "pc": "PC-CASA", "id": "a1b2c3d4", "as": "...Z" } }
#
# O email é da conta, não da instalação: antes de enviar, o PC reserva o slot do
# dia no Drive e só envia se a reserva continuar a ser dele passados uns segundos.
# Assim, com a app em vários PCs da mesma conta, só sai um email por hora agendada.

$script:PPE_ReservaEsperaSegundos  = 20  # tempo para a reserva do outro PC chegar ao Drive
$script:PPE_ReservaValidadeMinutos = 15  # reserva mais velha do que isto: esse PC desistiu

function Get-PPESharedEmailState {
    $file = Find-PPEDriveStateFile $script:PPE_EmailStateName
    if (-not $file) { return [pscustomobject]@{} }
    $text = Read-PPEDriveText $file.id
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    return $text | ConvertFrom-Json
}

function Set-PPESharedEmailValues([hashtable]$Values) {
    $state = Get-PPESharedEmailState
    foreach ($key in $Values.Keys) {
        $state | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] -Force
    }
    Write-PPEDriveText $script:PPE_EmailStateName ($state | ConvertTo-Json -Depth 5)
}

# Já enviado hoje por outro PC: alinha o registo local para não voltar a tentar
function Test-PPEAlreadySent($State, [string]$Slot, [string]$Day, [string]$StateKey) {
    if ($State.$StateKey -ne $Day) { return $false }
    Set-PPEStateValue $StateKey $Day
    Write-PPELog "Email $Slot já enviado hoje pelo $($State.($StateKey + 'By'))"
    return $true
}

# Reserva o envio deste slot para este PC. $false = fica para outro PC.
function Request-PPEEmailSlot([string]$Slot, [string]$Day, [string]$StateKey) {
    $me = Get-PPEInstallId
    $reservaKey = "reserva$Slot"
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal

    $state = Get-PPESharedEmailState
    if (Test-PPEAlreadySent $state $Slot $Day $StateKey) { return $false }

    # Outro PC está a tratar deste email neste momento
    $r = $state.$reservaKey
    if ($r -and $r.dia -eq $Day -and $r.id -ne $me.Id) {
        $idade = ([DateTime]::UtcNow - [DateTime]::Parse([string]$r.as, $script:INV, $styles)).TotalMinutes
        if ([Math]::Abs($idade) -lt $script:PPE_ReservaValidadeMinutos) {
            Write-PPELog "Email $Slot reservado pelo $($r.pc): este PC não envia"
            return $false
        }
    }

    Set-PPESharedEmailValues @{ $reservaKey = [pscustomobject]@{
        dia = $Day; pc = $me.Name; id = $me.Id; as = [DateTime]::UtcNow.ToString('o') } }

    # Se os dois PCs reservaram ao mesmo tempo, fica com o slot aquele cuja reserva
    # ficou gravada em último lugar — é a que ambos leem a seguir.
    Start-Sleep -Seconds $script:PPE_ReservaEsperaSegundos
    $state = Get-PPESharedEmailState
    if (Test-PPEAlreadySent $state $Slot $Day $StateKey) { return $false }
    $r = $state.$reservaKey
    if (-not $r -or $r.id -ne $me.Id) {
        $quem = if ($r) { $r.pc } else { 'outro PC' }
        Write-PPELog "Email $Slot reservado pelo ${quem}: este PC não envia"
        return $false
    }
    return $true
}

try {
    $config = Get-PPEConfig
    $now = Get-Date
    $todayKey = $now.ToString('yyyy-MM-dd')
    $stateKey = if ($Slot -eq 'Evening') { 'emailSentEvening' } else { 'emailSent' }

    $data = Read-PPEData $config
    $alerts = Get-PPEAlerts $data $config
    $plan = Get-PPEPlan -Data $data -Config $config

    if (-not $Preview -and -not $Force) {
        if (-not (Test-PPESlotDue $alerts (Get-PPEAlertSlot $alerts 'Email' $Slot) $data $config $now)) { return }
        if (-not (Request-PPEEmailSlot $Slot $todayKey $stateKey)) { return }
    }

    $nextPlan = $null
    if ($Slot -eq 'Evening') {
        $next = Get-PPENextWorkingDay $plan.Today $plan.Settings
        $nextPlan = Get-PPEPlan -Data $data -Config $config -Today $next -LabelDate $plan.Today
    }
    # Agenda do dia a que o email se refere (fim do dia: o próximo dia útil)
    $agendaDay = if ($nextPlan) { $nextPlan.Today } else { $plan.Today }
    $agenda = Get-PPEAgenda $data $agendaDay
    if ($agenda.Problem -eq 'sem-permissao' -and -not $Preview -and (Get-PPEState).agendaPermissaoAviso -ne $todayKey) {
        Set-PPEStateValue 'agendaPermissaoAviso' $todayKey
        try { Show-PPEToast -Config $config -Tag 'agenda' -Title 'PPEPlan — falta acesso ao Calendário' -Body 'Para a agenda aparecer nos emails e notificações: menu Iniciar → PPEPlan → Mudar conta Google.' } catch { }
    }
    $mail = New-PPEEmailHtml -Plan $plan -Config $config -Slot $Slot -NextPlan $nextPlan -Agenda $agenda
    $pushText = New-PPEPushText -Plan $plan -Config $config -Slot $Slot -NextPlan $nextPlan -Agenda $agenda

    if ($Preview) {
        $out = Join-Path $script:PPE_StateDir 'email-preview.html'
        [IO.File]::WriteAllText($out, $mail.Html, (New-Object Text.UTF8Encoding($true)))
        Write-Output "Assunto: $($mail.Subject)"
        Write-Output "Pré-visualização: $out"
        Write-Output ''
        Write-Output "Notificação no telemóvel: $($pushText.Title)"
        Write-Output $pushText.Body
        Start-Process $out
        return
    }

    $sendEmail = if ($Force) { $Canal -ne 'Push' } else { $alerts.SendEmail }
    $sendPush = -not $Force -or $Canal -ne 'Email'

    if ($sendEmail) { Send-PPEEmail $mail $alerts }
    # Um envio manual (-Force) também conta como o email do dia: evita que o disparo
    # automático/nova tentativa volte a enviar. Para testar sem afetar, usar -Preview
    # (ou -Canal Push, que só testa o telemóvel).
    if (-not ($Force -and $Canal -eq 'Push')) {
        Set-PPEStateValue $stateKey $todayKey
        $marca = @{}
        $marca[$stateKey] = $todayKey
        $marca[$stateKey + 'By'] = (Get-PPEInstallId).Name
        try { Set-PPESharedEmailValues $marca }
        catch { Write-PPELog "Aviso: não foi possível registar o envio no Drive: $($_.Exception.Message)" }
        if ($sendEmail) { Write-PPELog "Email $Slot enviado: $($mail.Subject)" }
        else { Write-PPELog "Email $Slot desligado nas Definições (só telemóvel)" }
    }

    # Uma falha no telemóvel não repete o email: fica no log e em ⚙ na app
    if ($sendPush) {
        try {
            $sent = Send-PPEPush -Title $pushText.Title -Body $pushText.Body -Tag $pushText.Tag -Url ([string]$config.appUrl)
            if ($sent -gt 0) { Write-PPELog "Push $Slot enviado para $sent dispositivo(s)" }
        }
        catch { Write-PPELog "ERRO Push ${Slot}: $($_.Exception.Message)" }
    }
}
catch {
    $err = $_.Exception.Message
    if ($_.Exception.InnerException) { $err += ' | ' + $_.Exception.InnerException.Message }
    Write-PPELog "ERRO Email ${Slot}: $err"
    if (-not $Preview) {
        # Envio automático: nova tentativa daqui a email.retryMinutes; avisa só uma vez por dia
        $day = (Get-Date).ToString('yyyy-MM-dd')
        $warn = $true
        if (-not $Force) {
            Set-PPEStateValue "emailFail$Slot" (Get-Date).ToString('o')
            $warn = (Get-PPEState).("emailFailToast$Slot") -ne $day
            Set-PPEStateValue "emailFailToast$Slot" $day
        }
        if ($warn) {
            try { Show-PPEToast -Title "PPEPlan — falha no email ($Slot)" -Body "$err`nNova tentativa automática dentro de minutos." -Tag 'email-error' -Config $config } catch { }
        }
    }
    throw
}
