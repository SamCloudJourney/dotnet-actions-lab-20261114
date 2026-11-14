$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Note([string]$message) { Write-Host "LAB04 $message" }
function Require([bool]$condition, [string]$message) {
    if (-not $condition) { throw "LAB04 ASSERTION FAILED: $message" }
}

Note "OS=$([System.Environment]::OSVersion.VersionString)"
Note "USER=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Note "SDK=$(dotnet --version)"

$features = @('Web-Server', 'Web-Url-Auth', 'Web-Mgmt-Tools', 'Web-Scripting-Tools')
$install = Install-WindowsFeature -Name $features -IncludeManagementTools
Note "IIS_FEATURES_SUCCESS=$($install.Success) RESTART_NEEDED=$($install.RestartNeeded)"
Require $install.Success 'IIS feature installation failed'
Require ($install.RestartNeeded -ne 'Yes') 'IIS feature installation requires a restart'

$bundleUrl = 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/11.0.0/dotnet-hosting-11.0.0-win.exe'
$bundleHash = 'ecba8c627d389bc07e8d5900d217cf1a05a0d814c2f3bacf218a49a5dbd2ac1ac2d5907c1934f2e858c346a2c8b34bf0bb5e6ee70d38a004332746decab4eab1'
$bundle = Join-Path $env:RUNNER_TEMP 'dotnet-hosting-11.0.0-win.exe'
Invoke-WebRequest -Uri $bundleUrl -OutFile $bundle -UseBasicParsing
$actualHash = (Get-FileHash -Path $bundle -Algorithm SHA512).Hash.ToLowerInvariant()
Require ($actualHash -eq $bundleHash) '11.0.0 hosting bundle hash mismatch'
$bundleInstall = Start-Process -FilePath $bundle -ArgumentList @('/install', '/quiet', '/norestart', 'OPT_NO_X86=1') -PassThru -Wait
Note "HOSTING_BUNDLE_EXIT=$($bundleInstall.ExitCode)"
Require ($bundleInstall.ExitCode -eq 0) 'Hosting bundle installation failed or requires restart'

$ancm = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
Require (Test-Path $ancm) 'ASP.NET Core Module V2 was not installed'
Note "ANCM_VERSION=$((Get-Item $ancm).VersionInfo.FileVersion)"
Note "RUNTIMES_START"
dotnet --list-runtimes
Note "RUNTIMES_END"

$source = Join-Path $env:RUNNER_TEMP 'hunt04-source'
$publish = Join-Path $env:RUNNER_TEMP 'hunt04-publish'
New-Item -ItemType Directory -Path $source -Force | Out-Null
Set-Content -Path (Join-Path $source 'IisPathLab.csproj') -Encoding utf8 -Value @'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net11.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AspNetCoreHostingModel>InProcess</AspNetCoreHostingModel>
  </PropertyGroup>
</Project>
'@
Set-Content -Path (Join-Path $source 'Program.cs') -Encoding utf8 -Value @'
using System.Diagnostics;
using Microsoft.AspNetCore.Http.Features;

var app = WebApplication.Create(args);

app.MapGet("/Delete", (HttpContext context) => Results.Text(Describe(context, "PUBLIC")));
app.MapGet("/Admin/Delete", (HttpContext context) => Results.Text(Describe(context, "PROTECTED_READ")));
app.MapPost("/Admin/Delete", (HttpContext context) =>
{
    Interlocked.Increment(ref LabState.Writes);
    return Results.Text(Describe(context, "PROTECTED_WRITE"));
});
app.MapGet("/State", () => Results.Text($"WRITES={Volatile.Read(ref LabState.Writes)}"));
app.Run();

static string Describe(HttpContext context, string marker) =>
    $"MARKER={marker};PATH={context.Request.Path};RAW={context.Features.Get<IHttpRequestFeature>()?.RawTarget};PROCESS={Process.GetCurrentProcess().ProcessName}";

static class LabState
{
    public static int Writes;
}
'@

dotnet publish (Join-Path $source 'IisPathLab.csproj') -c Release -o $publish --nologo
Require ($LASTEXITCODE -eq 0) 'dotnet publish failed'
$webConfig = Join-Path $publish 'web.config'
Set-Content -Path $webConfig -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    <aspNetCore processPath="dotnet" arguments=".\IisPathLab.dll" stdoutLogEnabled="false" hostingModel="InProcess" />
  </system.webServer>
  <location path="Admin">
    <system.webServer>
      <security>
        <authorization>
          <clear />
          <add accessType="Deny" users="*" />
        </authorization>
      </security>
    </system.webServer>
  </location>
</configuration>
'@

Import-Module WebAdministration
New-WebAppPool -Name 'Hunt04Pool' | Out-Null
Set-ItemProperty 'IIS:\AppPools\Hunt04Pool' -Name managedRuntimeVersion -Value ''
New-Website -Name 'Hunt04Lab' -Port 5087 -IPAddress '127.0.0.1' -PhysicalPath $publish -ApplicationPool 'Hunt04Pool' | Out-Null
$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
Note "IIS_AUTHZ_CONFIG_START"
& $appcmd list config 'Hunt04Lab/Admin' -section:system.webServer/security/authorization
Require ($LASTEXITCODE -eq 0) 'IIS did not load the Admin authorization configuration'
Note "IIS_AUTHZ_CONFIG_END"
Note "SITE_BINDINGS=$((Get-WebBinding -Name 'Hunt04Lab' | ForEach-Object { $_.bindingInformation }) -join ',')"

function Send-Raw([string]$verb, [string]$path) {
    $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', 5087)
    try {
        $client.ReceiveTimeout = 20000
        $client.SendTimeout = 20000
        $stream = $client.GetStream()
        $request = "$verb $path HTTP/1.1`r`nHost: 127.0.0.1:5087`r`nConnection: close`r`nContent-Length: 0`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $response = $reader.ReadToEnd()
        $match = [regex]::Match($response, '^HTTP/\d\.\d\s+(\d{3})')
        Require $match.Success "No HTTP status for $verb $path"
        $status = [int]$match.Groups[1].Value
        $sample = $response.Replace("`r", '').Replace("`n", '|')
        if ($sample.Length -gt 900) { $sample = $sample.Substring(0, 900) }
        Note "RESPONSE verb=$verb path=$path status=$status raw=$sample"
        return [pscustomobject]@{ Status = $status; Text = $response }
    }
    finally { $client.Dispose() }
}

function Is-Denied($response) { return $response.Status -in @(401, 403) -and $response.Text -notmatch 'MARKER=PROTECTED' }

$public = Send-Raw 'GET' '/Delete'
$directGet = Send-Raw 'GET' '/Admin/Delete'
$dotControl = Send-Raw 'GET' '/Admin/X/../Delete'
$stateBefore = Send-Raw 'GET' '/State'
$directPost = Send-Raw 'POST' '/Admin/Delete'
$stateAfterDirect = Send-Raw 'GET' '/State'
$craftedGet = Send-Raw 'GET' '/Admin//../Delete'
$craftedPost = Send-Raw 'POST' '/Admin//../Delete'
$stateAfterCrafted = Send-Raw 'GET' '/State'

$inprocBaseline = $public.Status -eq 200 -and $public.Text.Contains('MARKER=PUBLIC') -and $public.Text.Contains('PROCESS=w3wp')
$inprocGuard = (Is-Denied $directGet) -and (Is-Denied $dotControl) -and (Is-Denied $directPost)
$directWriteBlocked = $stateBefore.Text.Contains('WRITES=0') -and $stateAfterDirect.Text.Contains('WRITES=0')
$inprocBypass = $craftedGet.Status -eq 200 -and $craftedGet.Text.Contains('MARKER=PROTECTED_READ;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp')
$inprocEffect = $craftedPost.Status -eq 200 -and $craftedPost.Text.Contains('MARKER=PROTECTED_WRITE;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp') -and $stateAfterCrafted.Text.Contains('WRITES=1')
Note "INPROC_BASELINE=$inprocBaseline INPROC_GUARD=$inprocGuard DIRECT_WRITE_BLOCKED=$directWriteBlocked INPROC_BYPASS=$inprocBypass INPROC_EFFECT=$inprocEffect"

$outConfig = (Get-Content $webConfig -Raw).Replace('hostingModel="InProcess"', 'hostingModel="OutOfProcess"')
Set-Content -Path $webConfig -Encoding utf8 -Value $outConfig
Restart-WebAppPool -Name 'Hunt04Pool'
Start-Sleep -Seconds 3
$outPublic = Send-Raw 'GET' '/Delete'
$outDirect = Send-Raw 'GET' '/Admin/Delete'
$outCrafted = Send-Raw 'GET' '/Admin//../Delete'
$outprocBaseline = $outPublic.Status -eq 200 -and $outPublic.Text.Contains('MARKER=PUBLIC') -and $outPublic.Text.Contains('PROCESS=dotnet')
$outprocGuard = Is-Denied $outDirect
$outprocNoBypass = $outCrafted.Text -notmatch 'MARKER=PROTECTED' -and $outCrafted.Status -in @(200, 401, 403, 404)
Note "OUTPROC_BASELINE=$outprocBaseline OUTPROC_GUARD=$outprocGuard OUTPROC_NO_BYPASS=$outprocNoBypass"

Require $inprocBaseline 'In-process ASP.NET Core baseline did not run in w3wp'
Require $inprocGuard 'Direct or ordinary dot-segment path was not denied by IIS'
Require $directWriteBlocked 'Direct denial did not preserve write counter'
Require $inprocBypass 'Crafted path did not reach the protected read route in-process'
Require $inprocEffect 'Crafted POST did not cause the protected write effect in-process'
Require $outprocBaseline 'Out-of-process baseline did not run in dotnet'
Require $outprocGuard 'Direct URL was not denied out-of-process'
Require $outprocNoBypass 'Crafted path reached protected route out-of-process'
Note 'LAB04_FULL_CHAIN_PASS'
