# ============================================================
#  PPEPlan — funções partilhadas (notificações + email)
#  Replica o agendamento da app (index.html: priorityScore,
#  sortTasks, computeSchedule) para saber o que calha HOJE.
#
#  Instalado pelo PPEPlan-Setup.exe. Os dados vêm do Google Drive
#  da conta com que se entrou (PPEPlan-Google.ps1).
# ============================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:PPE_Root     = $PSScriptRoot
$script:PPE_StateDir = Join-Path $env:LOCALAPPDATA 'PPEPlan'
$script:PPE_AppId    = 'PPEPlan'
$script:PPE_PsAppId  = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$script:PT  = [Globalization.CultureInfo]::GetCultureInfo('pt-PT')
$script:INV = [Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path -LiteralPath $script:PPE_StateDir)) {
    New-Item -ItemType Directory -Path $script:PPE_StateDir | Out-Null
}

. (Join-Path $PSScriptRoot 'PPEPlan-Google.ps1')

# ---------- Config, estado e log ----------

function Merge-PPEObject($Base, $Override) {
    foreach ($p in $Override.PSObject.Properties) {
        $cur = $Base.PSObject.Properties[$p.Name]
        if ($cur -and $cur.Value -is [Management.Automation.PSCustomObject] -and $p.Value -is [Management.Automation.PSCustomObject]) {
            Merge-PPEObject $cur.Value $p.Value
        } else {
            $Base | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }
}

# config.default.json (vem com o instalador) + %LOCALAPPDATA%\PPEPlan\config.json
# (opcional, só com o que se quer mudar neste PC, ex.: {"email":{"time":"07:30"}})
function Get-PPEConfig {
    $config = Get-Content -LiteralPath (Join-Path $script:PPE_Root 'config.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $userPath = Join-Path $script:PPE_StateDir 'config.json'
    if (Test-Path -LiteralPath $userPath) {
        Merge-PPEObject $config (Get-Content -LiteralPath $userPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return $config
}

function Write-PPELog([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath (Join-Path $script:PPE_StateDir 'ppeplan.log') -Value $line -Encoding UTF8
}

function Get-PPEState {
    $path = Join-Path $script:PPE_StateDir 'state.json'
    if (Test-Path -LiteralPath $path) {
        try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{}
}

function Set-PPEStateValue([string]$Key, $Value) {
    $state = Get-PPEState
    $state | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:PPE_StateDir 'state.json') -Encoding UTF8
}

# Como este PC se identifica no registo partilhado da conta. O nome do PC pode
# repetir-se, por isso junta-se um id gerado na primeira utilização.
function Get-PPEInstallId {
    $id = [string](Get-PPEState).installId
    if (-not $id) {
        $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Set-PPEStateValue 'installId' $id
    }
    [pscustomobject]@{ Id = $id; Name = $env:COMPUTERNAME }
}

function ConvertTo-TodayTime([string]$HHmm) {
    [DateTime]::ParseExact($HHmm, 'HH:mm', $script:INV)
}

# ---------- Datas (mesma semântica do JS) ----------

# new Date("YYYY-MM-DD") em JS = meia-noite UTC; convertida para hora local
function ConvertFrom-JsDate([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    return [DateTime]::Parse($s, $script:INV, $styles).ToLocalTime()
}

# Data de calendário (para mostrar "atrasada 3 dias", "prazo hoje", ...)
function ConvertFrom-IsoDay([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return [DateTime]::ParseExact($s.Substring(0, 10), 'yyyy-MM-dd', $script:INV)
}

function Format-PPEDay([DateTime]$d, [string]$fmt = 'ddd, d MMM') {
    $d.ToString($fmt, $script:PT)
}

function Test-PPEWorkingDay([DateTime]$d, $settings) {
    if ($settings.workWeekends) { return $true }
    return ($d.DayOfWeek -ne [DayOfWeek]::Saturday -and $d.DayOfWeek -ne [DayOfWeek]::Sunday)
}

function Get-PPENextWorkingDay([DateTime]$d, $settings) {
    $n = $d.Date.AddDays(1)
    while (-not (Test-PPEWorkingDay $n $settings)) { $n = $n.AddDays(1) }
    return $n
}

# ---------- Dados e agendamento ----------

# Lê o ppeplan-data.json do Drive. Sem rede, usa a última cópia descarregada
# (o aviso de "dados desatualizados" do email/notificação continua a funcionar pelo savedAt).
# Só descarrega quando o ficheiro mudou no Drive (o agendador corre de 5 em 5 minutos).
# -Quiet: não regista no log quando usa a cópia por falta de rede.
function Read-PPEData($Config, [switch]$Quiet) {
    $cache = Join-Path $script:PPE_StateDir 'data-cache.json'
    $cacheMod = Join-Path $script:PPE_StateDir 'data-cache.modified'
    $utf8 = New-Object Text.UTF8Encoding($false)
    try {
        $file = Find-PPEDriveFile $script:PPE_DataFileName
        if (-not $file) {
            throw "Não há $($script:PPE_DataFileName) no Google Drive de $((Get-PPEGoogleAccount).Email). Abre o PPEPlan e entra com essa conta."
        }
        $known = if (Test-Path -LiteralPath $cacheMod) { [IO.File]::ReadAllText($cacheMod).Trim() } else { '' }
        if ((Test-Path -LiteralPath $cache) -and $known -and $known -eq [string]$file.modifiedTime) {
            $text = [IO.File]::ReadAllText($cache, [Text.Encoding]::UTF8)
        } else {
            $text = Read-PPEDriveText $file.id
            [IO.File]::WriteAllText($cache, $text, $utf8)
            [IO.File]::WriteAllText($cacheMod, [string]$file.modifiedTime, $utf8)
        }
    }
    catch {
        if (-not (Test-Path -LiteralPath $cache)) { throw }
        if (-not $Quiet) { Write-PPELog "Drive indisponível, a usar a última cópia: $($_.Exception.Message)" }
        $text = [IO.File]::ReadAllText($cache, [Text.Encoding]::UTF8)
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ tasks = @() } }
    return $text | ConvertFrom-Json
}

function Get-PPESettings($Data) {
    $s = $Data.settings
    $w = if ($s -and $s.weights) { $s.weights } else { $null }
    [pscustomobject]@{
        dailyHours   = if ($s -and $s.dailyHours) { [double]$s.dailyHours } else { 8 }
        workWeekends = [bool]($s -and $s.workWeekends)
        wDeadline    = if ($w -and $null -ne $w.deadline) { [double]$w.deadline } else { 0.40 }
        wSlack       = if ($w -and $null -ne $w.slack)    { [double]$w.slack }    else { 0.35 }
        wPriority    = if ($w -and $null -ne $w.priority) { [double]$w.priority } else { 0.25 }
    }
}

# ---------- Horários (Definições da app: settings.alerts) ----------

# Horas e ligar/desligar vêm da app (iguais em todos os PCs da conta);
# config.notifications.enabled desliga as notificações só neste PC.
function Get-PPEAlerts($Data, $Config) {
    $defs = @(
        @{ Key = 'emailMorning';   Kind = 'Email';  Slot = 'Morning';  Time = '08:00'; StateKey = 'emailSent' },
        @{ Key = 'emailEvening';   Kind = 'Email';  Slot = 'Evening';  Time = '18:00'; StateKey = 'emailSentEvening' },
        @{ Key = 'notifyMorning';  Kind = 'Notify'; Slot = 'Morning';  Time = '09:00'; StateKey = 'toastMorning' },
        @{ Key = 'notifyMidday';   Kind = 'Notify'; Slot = 'Midday';   Time = '14:00'; StateKey = 'toastMidday' },
        @{ Key = 'notifyEndOfDay'; Kind = 'Notify'; Slot = 'EndOfDay'; Time = '17:30'; StateKey = 'toastEndOfDay' }
    )
    $a = if ($Data -and $Data.settings -and $Data.settings.alerts) { $Data.settings.alerts } else { $null }
    $slots = foreach ($d in $defs) {
        $s = if ($a) { $a.($d.Key) } else { $null }
        [pscustomobject]@{
            Key = $d.Key; Kind = $d.Kind; Slot = $d.Slot; StateKey = $d.StateKey
            Time = if ($s -and ([string]$s.time) -match '^\d{2}:\d{2}$') { [string]$s.time } else { $d.Time }
            On   = if ($s -and $null -ne $s.on) { [bool]$s.on } else { $true }
        }
    }
    [pscustomobject]@{
        Slots          = @($slots)
        EmailTo        = if ($a -and $a.emailTo) { [string]$a.emailTo } else { '' }
        NotifyOnThisPC = [bool]$Config.notifications.enabled
    }
}

function Get-PPEAlertSlot($Alerts, [string]$Kind, [string]$Slot) {
    $Alerts.Slots | Where-Object { $_.Kind -eq $Kind -and $_.Slot -eq $Slot } | Select-Object -First 1
}

# Está na hora de enviar este email / mostrar esta notificação (e ainda não foi feito hoje)?
function Test-PPESlotDue($Alerts, $SlotInfo, $Data, $Config, [DateTime]$Now = (Get-Date)) {
    if (-not $SlotInfo -or -not $SlotInfo.On) { return $false }
    if ($SlotInfo.Kind -eq 'Notify' -and -not $Alerts.NotifyOnThisPC) { return $false }
    if (-not (Test-PPEWorkingDay $Now.Date (Get-PPESettings $Data))) { return $false }
    $state = Get-PPEState
    if ($state.($SlotInfo.StateKey) -eq $Now.ToString('yyyy-MM-dd')) { return $false }
    $at = $Now.Date.Add([TimeSpan]::ParseExact($SlotInfo.Time, 'hh\:mm', $script:INV))
    if ($Now -lt $at) { return $false }
    if ($SlotInfo.Kind -eq 'Notify') {
        # PC ligado muito depois da hora: já não faz sentido mostrar
        return ($Now -le $at.AddMinutes([int]$Config.notifications.lateToleranceMinutes))
    }
    if ($SlotInfo.Slot -eq 'Morning') {
        # O email da manhã não sai depois da hora do email de fim do dia
        $evening = Get-PPEAlertSlot $Alerts 'Email' 'Evening'
        if ($evening.On -and $Now -ge $Now.Date.Add([TimeSpan]::ParseExact($evening.Time, 'hh\:mm', $script:INV))) { return $false }
    }
    # Depois de uma falha, espera antes de tentar outra vez
    $fail = $state.("emailFail$($SlotInfo.Slot)")
    if ($fail -and ($Now - [DateTime]::Parse($fail, $script:INV)).TotalMinutes -lt [double]$Config.email.retryMinutes) { return $false }
    return $true
}

function Get-PPEPriorityScore($Task, $Settings, [DateTime]$Today) {
    if ($Task.status -eq 'completed') { return -1 }
    $dl = ConvertFrom-JsDate $Task.deadline
    if ($null -eq $dl) { return 0 }
    $daysUntil = [Math]::Max(-1000, ($dl - $Today).TotalDays)
    $slack = $daysUntil - ([double]$Task.estimatedHours / $Settings.dailyHours)
    if ($daysUntil -lt 0) { $ds = 100 + [Math]::Min(50, -$daysUntil * 5) } else { $ds = 100 * [Math]::Exp(-$daysUntil / 10) }
    if ($slack -lt 0)     { $ss = 100 + [Math]::Min(50, -$slack * 5) }     else { $ss = [Math]::Max(0, 100 - $slack * 10) }
    $ps = ([double]$Task.manualPriority - 1) * 25
    return $Settings.wDeadline * $ds + $Settings.wSlack * $ss + $Settings.wPriority * $ps
}

# Devolve as tarefas ativas pela ordem da app, cada uma com o seu plano diário.
function Get-PPEPlan {
    # -Today: dia a partir do qual se agenda (a app usa sempre hoje)
    # -LabelDate: dia de referência para "prazo amanhã", "atrasada 2 dias" (por defeito = Today)
    param($Data, $Config, [DateTime]$Today = (Get-Date).Date, [Nullable[DateTime]]$LabelDate = $null)
    $refDay = if ($null -ne $LabelDate) { ([DateTime]$LabelDate).Date } else { $Today }

    $settings = Get-PPESettings $Data
    $mine = @('me') + @($Config.myInitials | ForEach-Object { ([string]$_).ToUpper() })
    $tasks = @($Data.tasks)

    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $t = $tasks[$i]
        if ($t.status -eq 'completed') { continue }
        $assignee = if ($t.assignee) { ([string]$t.assignee).ToUpper() } else { 'me' }
        $deadlineDay = ConvertFrom-IsoDay $t.deadline
        $items.Add([pscustomobject]@{
            Index       = $i
            Task        = $t
            Assignee    = $assignee
            IsMine      = $mine -contains $assignee
            Score       = Get-PPEPriorityScore $t $settings $Today
            Schedule    = New-Object System.Collections.Generic.List[object]
            HoursToday  = 0
            Start       = $null
            End         = $null
            Risk        = 'ok'
            DeadlineDay = $deadlineDay
            DaysToDeadline = if ($deadlineDay) { [int]($deadlineDay - $refDay).TotalDays } else { $null }
            PendingSubtasks = @($t.subtasks | Where-Object { $_ -and $_.status -ne 'completed' })
        })
    }

    # sortTasks: primeiro ordem manual, depois score descendente (ordenação estável)
    $manual = @($items | Where-Object { $null -ne $_.Task.manualOrder } |
        Sort-Object @{ Expression = { [double]$_.Task.manualOrder } }, @{ Expression = { $_.Index } })
    $auto = @($items | Where-Object { $null -eq $_.Task.manualOrder } |
        Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Index }; Descending = $false })
    $ordered = @($manual) + @($auto)

    # computeSchedule: cada delegado tem as suas horas diárias
    $todayKey = $Today.ToString('yyyy-MM-dd')
    $usage = @{}
    foreach ($it in $ordered) {
        if (-not $usage.ContainsKey($it.Assignee)) { $usage[$it.Assignee] = @{} }
        $du = $usage[$it.Assignee]
        $r = [double]$it.Task.estimatedHours
        $d = $Today
        $sf = 0
        while ($r -gt 0 -and $sf -lt 365) {
            if (Test-PPEWorkingDay $d $settings) {
                $k = $d.ToString('yyyy-MM-dd')
                $u = [double]$du[$k]
                $av = $settings.dailyHours - $u
                if ($av -gt 0) {
                    $al = [Math]::Min($r, $av)
                    $du[$k] = $u + $al
                    $it.Schedule.Add([pscustomobject]@{ Date = $k; Hours = $al })
                    $r -= $al
                }
            }
            $d = $d.AddDays(1); $sf++
        }
        if ($it.Schedule.Count -gt 0) {
            $it.Start = $it.Schedule[0].Date
            $it.End = $it.Schedule[$it.Schedule.Count - 1].Date
            $todayEntry = $it.Schedule | Where-Object { $_.Date -eq $todayKey } | Select-Object -First 1
            if ($todayEntry) { $it.HoursToday = $todayEntry.Hours }
            $dl = ConvertFrom-JsDate $it.Task.deadline
            if ($dl) {
                $sl = ($dl - (ConvertFrom-JsDate $it.End)).TotalDays
                $it.Risk = if ($sl -lt 0) { 'risk' } elseif ($sl -lt 2) { 'tight' } else { 'ok' }
            }
        }
    }

    [pscustomobject]@{
        Today     = $Today
        Settings  = $settings
        Ordered   = $ordered
        MyToday   = @($ordered | Where-Object { $_.IsMine -and $_.HoursToday -gt 0 })
        Delegated = @($ordered | Where-Object { -not $_.IsMine -and $_.HoursToday -gt 0 })
        Overdue   = @($ordered | Where-Object { $_.IsMine -and $null -ne $_.DaysToDeadline -and $_.DaysToDeadline -lt 0 })
        DueToday  = @($ordered | Where-Object { $_.IsMine -and $_.DaysToDeadline -eq 0 })
        CompletedToday = @($tasks | Where-Object {
            $_.status -eq 'completed' -and $_.completedAt -and ([DateTime]::Parse($_.completedAt, $script:INV)).ToLocalTime().Date -eq $Today })
        SavedAt   = if ($Data.savedAt) { ([DateTime]::Parse($Data.savedAt, $script:INV)).ToLocalTime() } else { $null }
    }
}

function Format-PPEHours([double]$h) {
    if ($h -eq [Math]::Floor($h)) { return ('{0}h' -f [int]$h) }
    return ($h.ToString('0.#', $script:PT) + 'h')
}

function Get-PPEDeadlineLabel($Item) {
    $n = $Item.DaysToDeadline
    if ($null -eq $n) { return 'sem prazo' }
    if ($n -lt -1) { return "atrasada $(-$n) dias" }
    if ($n -eq -1) { return 'atrasada 1 dia' }
    if ($n -eq 0)  { return 'prazo hoje' }
    if ($n -eq 1)  { return 'prazo amanhã' }
    return 'prazo ' + (Format-PPEDay $Item.DeadlineDay 'd MMM')
}

# ---------- Notificações Windows ----------

function Show-PPEToast {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [string]$Body = '',
        [string]$Attribution = '',
        [string]$Tag = 'ppeplan',
        [switch]$Reminder,
        $Config
    )
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $url = if ($Config -and $Config.appUrl) { [string]$Config.appUrl } else { '' }
    $icon = Join-Path $script:PPE_StateDir 'icon.png'

    $launch = if ($url) { " activationType=`"protocol`" launch=`"$(& $esc $url)`"" } else { '' }
    $scenario = if ($Reminder) { ' scenario="reminder"' } else { '' }
    $logo = if (Test-Path -LiteralPath $icon) { "<image placement=`"appLogoOverride`" src=`"$(& $esc $icon)`"/>" } else { '' }
    $attr = if ($Attribution) { "<text placement=`"attribution`">$(& $esc $Attribution)</text>" } else { '' }

    $actions = ''
    if ($url -or $Reminder) {
        $actions = '<actions>'
        if ($url) { $actions += "<action content=`"Abrir PPEPlan`" activationType=`"protocol`" arguments=`"$(& $esc $url)`"/>" }
        $actions += '<action content="Dispensar" activationType="system" arguments="dismiss"/></actions>'
    }

    $xmlText = @"
<toast$launch$scenario>
  <visual><binding template="ToastGeneric">
    $logo
    <text>$(& $esc $Title)</text>
    <text>$(& $esc $Body)</text>
    $attr
  </binding></visual>
  $actions
</toast>
"@
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($xmlText)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $toast.Tag = $Tag
    $toast.Group = 'PPEPlan'

    $appId = if (Test-Path "HKCU:\Software\Classes\AppUserModelId\$($script:PPE_AppId)") { $script:PPE_AppId } else { $script:PPE_PsAppId }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}
