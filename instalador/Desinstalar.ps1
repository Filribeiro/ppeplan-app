# ============================================================
#  PPEPlan — remove tarefas agendadas e registo de notificações
#  (corre automaticamente ao desinstalar pelo Windows)
#  -Tudo  também termina a sessão Google e apaga %LOCALAPPDATA%\PPEPlan
# ============================================================
param([switch]$Tudo)

Get-ScheduledTask -TaskName 'PPEPlan - *' -ErrorAction SilentlyContinue | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
    Write-Host "Removida: $($_.TaskName)"
}
Remove-Item -Path 'HKCU:\Software\Classes\AppUserModelId\PPEPlan' -Recurse -ErrorAction SilentlyContinue

if ($Tudo) {
    $tokenPath = Join-Path $env:LOCALAPPDATA 'PPEPlan\google-token.xml'
    if (Test-Path -LiteralPath $tokenPath) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $refresh = (Import-Clixml -LiteralPath $tokenPath).GetNetworkCredential().Password
            Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/revoke' -Body @{ token = $refresh } | Out-Null
        } catch { }
    }
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'PPEPlan') -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PPEPlan desinstalado.'
