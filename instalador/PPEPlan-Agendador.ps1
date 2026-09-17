# ============================================================
#  PPEPlan — agendador (tarefa "PPEPlan - Agendador", de 5 em 5 minutos)
#  Lê as horas das Definições da app (no Drive) e chama o email ou a
#  notificação que estiver na hora. Mudar horas na app não obriga a reinstalar.
#  De hora a hora verifica se há scripts novos publicados (PPEPlan-Atualizar.ps1).
# ============================================================

. (Join-Path $PSScriptRoot 'PPEPlan-Common.ps1')

try {
    $updated = $false
    try { $updated = [bool](@(& (Join-Path $PSScriptRoot 'PPEPlan-Atualizar.ps1')) | Select-Object -Last 1) }
    catch { Write-PPELog "Aviso: verificação de atualizações falhou: $($_.Exception.Message)" }
    # Scripts novos: a próxima execução (daqui a 5 min) já corre toda com a versão nova
    if ($updated) { return }

    $config = Get-PPEConfig
    if (-not (Get-PPEGoogleAccount)) { return }
    # Dá sinal de vida na lista de PCs da conta (não é motivo para falhar o resto)
    try { Update-PPEPcStatus $config } catch { }
    $data = Read-PPEData $config -Quiet

    # Notificação de teste pedida na app: só lê o ficheiro (e compila o push) quando mudou
    try {
        $pf = Find-PPEDriveStateFile $script:PPE_PushFileName
        if ($pf -and [string]$pf.modifiedTime -ne [string](Get-PPEState).pushFileModified) {
            Set-PPEStateValue 'pushFileModified' ([string]$pf.modifiedTime)
            $pushText = Read-PPEDriveText $pf.id
            if ($pushText -match '"testePedido"') {
                . (Join-Path $PSScriptRoot 'PPEPlan-Push.ps1')
                Invoke-PPEPushTest ($pushText | ConvertFrom-Json) $config
            }
        }
    } catch { Write-PPELog "ERRO Push teste: $($_.Exception.Message)" }

    $alerts = Get-PPEAlerts $data $config
    $now = Get-Date
    foreach ($s in $alerts.Slots) {
        if (-not (Test-PPESlotDue $alerts $s $data $config $now)) { continue }
        $file = if ($s.Kind -eq 'Email') { 'PPEPlan-Email.ps1' } else { 'PPEPlan-Notify.ps1' }
        # Os scripts registam os próprios erros no log
        try { & (Join-Path $PSScriptRoot $file) -Slot $s.Slot } catch { }
    }
}
catch {
    # Sem rede ou sem dados: regista no máximo uma vez por hora a mesma mensagem
    $msg = $_.Exception.Message
    $key = (Get-Date).ToString('yyyy-MM-dd HH') + '|' + $msg
    if ((Get-PPEState).agendadorLastError -ne $key) {
        Set-PPEStateValue 'agendadorLastError' $key
        Write-PPELog "ERRO Agendador: $msg"
    }
}
