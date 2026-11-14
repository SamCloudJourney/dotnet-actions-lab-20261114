$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Note([string]$message) { Write-Host "LAB04 $message" }
function Require([bool]$condition, [string]$message) {
    if (-not $condition) { throw "LAB04 ASSERTION FAILED: $message" }
}

Note "OS=$([System.Environment]::OSVersion.VersionString)"
Note "USER=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Note "SDK=$(dotnet --version)"

$features = @('Web-Server', 'Web-Url-Auth', 'Web-IP-Security', 'Web-Windows-Auth', 'Web-Mgmt-Tools', 'Web-Scripting-Tools')
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
$staticDir = Join-Path $source 'wwwroot\Admin'
New-Item -ItemType Directory -Path $staticDir -Force | Out-Null
Set-Content -Path (Join-Path $staticDir 'secret.txt') -Encoding ascii -Value 'STATIC_PROTECTED_CONTENT_04'
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
using System.Runtime.InteropServices;
using Microsoft.AspNetCore.Http.Features;

var app = WebApplication.Create(args);
app.UseStaticFiles();

app.MapGet("/Delete", (HttpContext context) => Results.Text(Describe(context, "PUBLIC")));
app.MapGet("/Admin/Delete", (HttpContext context) => Results.Text(Describe(context, "PROTECTED_READ")));
app.MapPost("/Admin/Delete", (HttpContext context) =>
{
    Interlocked.Increment(ref LabState.Writes);
    return Results.Text(Describe(context, "PROTECTED_WRITE"));
});
app.MapGet("/State", () => Results.Text($"WRITES={Volatile.Read(ref LabState.Writes)}"));
app.Run();

static string Describe(HttpContext context, string marker)
{
    var isAdmin = context.User.IsInRole(@"BUILTIN\Administrators");
    return $"MARKER={marker};PATH={context.Request.Path};RAW={context.Features.Get<IHttpRequestFeature>()?.RawTarget};PROCESS={Process.GetCurrentProcess().ProcessName};FRAMEWORK={RuntimeInformation.FrameworkDescription};AUTH={context.User.Identity?.IsAuthenticated};NAME={context.User.Identity?.Name};ADMIN={isAdmin}";
}

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

function Send-Raw([string]$verb, [string]$path, [int]$port = 5087) {
    $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    try {
        $client.ReceiveTimeout = 20000
        $client.SendTimeout = 20000
        $stream = $client.GetStream()
        $request = "$verb $path HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nConnection: close`r`nContent-Length: 0`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $response = $reader.ReadToEnd()
        $match = [regex]::Match($response, '^HTTP/\d\.\d\s+(\d{3})')
        Require $match.Success "No HTTP status for $verb $path"
        $status = [int]$match.Groups[1].Value
        $sample = $response.Replace("`r", '').Replace("`n", '|')
        if ($sample.Length -gt 900) { $sample = $sample.Substring(0, 900) }
        Note "RESPONSE port=$port verb=$verb path=$path status=$status raw=$sample"
        return [pscustomobject]@{ Status = $status; Text = $response }
    }
    finally { $client.Dispose() }
}

function Is-Denied($response) { return $response.Status -in @(401, 403) -and $response.Text -notmatch 'MARKER=PROTECTED' }

$public = Send-Raw 'GET' '/Delete'
$directGet = Send-Raw 'GET' '/Admin/Delete'
$dotControl = Send-Raw 'GET' '/Admin/X/../Delete'
$staticDirect = Send-Raw 'GET' '/Admin/secret.txt'
$stateBefore = Send-Raw 'GET' '/State'
$directPost = Send-Raw 'POST' '/Admin/Delete'
$stateAfterDirect = Send-Raw 'GET' '/State'
$craftedGet = Send-Raw 'GET' '/Admin//../Delete'
$staticCrafted = Send-Raw 'GET' '/Admin//../secret.txt'
$craftedPost = Send-Raw 'POST' '/Admin//../Delete'
$stateAfterCrafted = Send-Raw 'GET' '/State'

$inprocBaseline = $public.Status -eq 200 -and $public.Text.Contains('MARKER=PUBLIC') -and $public.Text.Contains('PROCESS=w3wp')
$inprocGuard = (Is-Denied $directGet) -and (Is-Denied $dotControl) -and (Is-Denied $directPost) -and (Is-Denied $staticDirect)
$directWriteBlocked = $stateBefore.Text.Contains('WRITES=0') -and $stateAfterDirect.Text.Contains('WRITES=0')
$inprocBypass = $craftedGet.Status -eq 200 -and $craftedGet.Text.Contains('MARKER=PROTECTED_READ;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp')
$inprocEffect = $craftedPost.Status -eq 200 -and $craftedPost.Text.Contains('MARKER=PROTECTED_WRITE;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp') -and $stateAfterCrafted.Text.Contains('WRITES=1')
$inprocStatic = $staticCrafted.Status -eq 200 -and $staticCrafted.Text.Contains('STATIC_PROTECTED_CONTENT_04')
Note "INPROC_BASELINE=$inprocBaseline INPROC_GUARD=$inprocGuard DIRECT_WRITE_BLOCKED=$directWriteBlocked INPROC_BYPASS=$inprocBypass INPROC_EFFECT=$inprocEffect INPROC_STATIC=$inprocStatic"

$outConfig = (Get-Content $webConfig -Raw).Replace('hostingModel="InProcess"', 'hostingModel="OutOfProcess"')
Set-Content -Path $webConfig -Encoding utf8 -Value $outConfig
Restart-WebAppPool -Name 'Hunt04Pool'
Start-Sleep -Seconds 3
$outPublic = Send-Raw 'GET' '/Delete'
$outDirect = Send-Raw 'GET' '/Admin/Delete'
$outCrafted = Send-Raw 'GET' '/Admin//../Delete'
$outStaticDirect = Send-Raw 'GET' '/Admin/secret.txt'
$outStaticCrafted = Send-Raw 'GET' '/Admin//../secret.txt'
$outprocBaseline = $outPublic.Status -eq 200 -and $outPublic.Text.Contains('MARKER=PUBLIC') -and $outPublic.Text.Contains('PROCESS=dotnet')
$outprocGuard = (Is-Denied $outDirect) -and (Is-Denied $outStaticDirect)
$outprocNoBypass = $outCrafted.Text -notmatch 'MARKER=PROTECTED' -and $outCrafted.Status -in @(200, 401, 403, 404)
$outprocStaticSafe = $outStaticCrafted.Text -notmatch 'STATIC_PROTECTED_CONTENT_04' -and $outStaticCrafted.Status -in @(200, 401, 403, 404)
Note "OUTPROC_BASELINE=$outprocBaseline OUTPROC_GUARD=$outprocGuard OUTPROC_NO_BYPASS=$outprocNoBypass OUTPROC_STATIC_SAFE=$outprocStaticSafe"

$ipConfig = [regex]::Replace($outConfig, '(?s)<location path="Admin">.*?</location>', '')
$ipConfig = $ipConfig.Replace('hostingModel="OutOfProcess"', 'hostingModel="InProcess"')
Set-Content -Path $webConfig -Encoding utf8 -Value $ipConfig
& $appcmd set config 'Hunt04Lab/Admin' -section:system.webServer/security/ipSecurity '/allowUnlisted:false' '/denyAction:Forbidden' '/commit:apphost'
Require ($LASTEXITCODE -eq 0) 'Could not configure scoped IIS IP restriction'
Note 'IIS_IP_CONFIG_START'
& $appcmd list config 'Hunt04Lab/Admin' -section:system.webServer/security/ipSecurity
Require ($LASTEXITCODE -eq 0) 'IIS did not load the Admin IP restriction'
Note 'IIS_IP_CONFIG_END'
Restart-WebAppPool -Name 'Hunt04Pool'
Start-Sleep -Seconds 3
$ipPublic = Send-Raw 'GET' '/Delete'
$ipDirect = Send-Raw 'GET' '/Admin/Delete'
$ipCrafted = Send-Raw 'GET' '/Admin//../Delete'
$ipBaseline = $ipPublic.Status -eq 200 -and $ipPublic.Text.Contains('MARKER=PUBLIC') -and $ipPublic.Text.Contains('PROCESS=w3wp')
$ipGuard = $ipDirect.Status -eq 403 -and $ipDirect.Text -notmatch 'MARKER=PROTECTED'
$ipBypass = $ipCrafted.Status -eq 200 -and $ipCrafted.Text.Contains('MARKER=PROTECTED_READ;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp')
Note "IP_BASELINE=$ipBaseline IP_GUARD=$ipGuard IP_BYPASS=$ipBypass"

Require $inprocBaseline 'In-process ASP.NET Core baseline did not run in w3wp'
Require $inprocGuard 'Direct or ordinary dot-segment path was not denied by IIS'
Require $directWriteBlocked 'Direct denial did not preserve write counter'
Require $inprocBypass 'Crafted path did not reach the protected read route in-process'
Require $inprocEffect 'Crafted POST did not cause the protected write effect in-process'
Require $inprocStatic 'Crafted path did not disclose the IIS-protected static file'
Require $outprocBaseline 'Out-of-process baseline did not run in dotnet'
Require $outprocGuard 'Direct URL was not denied out-of-process'
Require $outprocNoBypass 'Crafted path reached protected route out-of-process'
Require $outprocStaticSafe 'Crafted path disclosed static file out-of-process'
Require $ipBaseline 'In-process baseline failed under IP restrictions'
Require $ipGuard 'Scoped IP restriction did not deny direct Admin path'
Require $ipBypass 'Crafted path did not bypass the scoped IP restriction'
Note 'LAB04_11_0_0_PASS'

$tenRuntimeUrl = 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/10.0.15/aspnetcore-runtime-10.0.15-win-x64.exe'
$tenRuntimeHash = '716a82305a97b74fed21a982af4ca0f6d2c68489b6bfd1a88d565f8dbc73591873eb6c9e5289af6686e1b0a8090501ee920bb65e83dd506ff71f6ad932edc8d1'
$tenRuntimeInstaller = Join-Path $env:RUNNER_TEMP 'aspnetcore-runtime-10.0.15-win-x64.exe'
Invoke-WebRequest -Uri $tenRuntimeUrl -OutFile $tenRuntimeInstaller -UseBasicParsing
$tenActualHash = (Get-FileHash -Path $tenRuntimeInstaller -Algorithm SHA512).Hash.ToLowerInvariant()
Require ($tenActualHash -eq $tenRuntimeHash) '10.0.15 ASP.NET Core runtime hash mismatch'
$tenInstall = Start-Process -FilePath $tenRuntimeInstaller -ArgumentList @('/install', '/quiet', '/norestart') -PassThru -Wait
Note "TEN_RUNTIME_INSTALL_EXIT=$($tenInstall.ExitCode)"
Require ($tenInstall.ExitCode -eq 0) '10.0.15 ASP.NET Core runtime installation failed'
$runtimeList = (dotnet --list-runtimes) -join "`n"
Require ($runtimeList -match 'Microsoft\.AspNetCore\.App 10\.0\.15') '10.0.15 ASP.NET Core runtime is absent'

$tenSource = Join-Path $env:RUNNER_TEMP 'hunt04-source10'
$tenPublish = Join-Path $env:RUNNER_TEMP 'hunt04-publish10'
New-Item -ItemType Directory -Path $tenSource -Force | Out-Null
Copy-Item (Join-Path $source 'Program.cs') (Join-Path $tenSource 'Program.cs')
Copy-Item (Join-Path $source 'wwwroot') (Join-Path $tenSource 'wwwroot') -Recurse
$tenProject = (Get-Content (Join-Path $source 'IisPathLab.csproj') -Raw).Replace('net11.0', 'net10.0')
Set-Content -Path (Join-Path $tenSource 'IisPathLab.csproj') -Encoding utf8 -Value $tenProject
dotnet publish (Join-Path $tenSource 'IisPathLab.csproj') -c Release -o $tenPublish --nologo
Require ($LASTEXITCODE -eq 0) '10.0.15 app publish failed'
Set-Content -Path (Join-Path $tenPublish 'web.config') -Encoding utf8 -Value $ipConfig

New-WebAppPool -Name 'Hunt04TenPool' | Out-Null
Set-ItemProperty 'IIS:\AppPools\Hunt04TenPool' -Name managedRuntimeVersion -Value ''
New-Website -Name 'Hunt04TenLab' -Port 5088 -IPAddress '127.0.0.1' -PhysicalPath $tenPublish -ApplicationPool 'Hunt04TenPool' | Out-Null
& $appcmd set config 'Hunt04TenLab/Admin' -section:system.webServer/security/ipSecurity '/allowUnlisted:false' '/denyAction:Forbidden' '/commit:apphost'
Require ($LASTEXITCODE -eq 0) 'Could not configure .NET 10 scoped IP restriction'
$tenPublic = Send-Raw 'GET' '/Delete' 5088
$tenDirect = Send-Raw 'GET' '/Admin/Delete' 5088
$tenStaticDirect = Send-Raw 'GET' '/Admin/secret.txt' 5088
$tenStateBefore = Send-Raw 'GET' '/State' 5088
$tenPostDirect = Send-Raw 'POST' '/Admin/Delete' 5088
$tenStateAfterDirect = Send-Raw 'GET' '/State' 5088
$tenCrafted = Send-Raw 'GET' '/Admin//../Delete' 5088
$tenStaticCrafted = Send-Raw 'GET' '/Admin//../secret.txt' 5088
$tenPostCrafted = Send-Raw 'POST' '/Admin//../Delete' 5088
$tenStateAfterCrafted = Send-Raw 'GET' '/State' 5088
$tenBaseline = $tenPublic.Status -eq 200 -and $tenPublic.Text.Contains('MARKER=PUBLIC') -and $tenPublic.Text.Contains('PROCESS=w3wp;FRAMEWORK=.NET 10.0.15')
$tenGuard = $tenDirect.Status -eq 403 -and $tenStaticDirect.Status -eq 403 -and $tenPostDirect.Status -eq 403
$tenDirectWriteBlocked = $tenStateBefore.Text.Contains('WRITES=0') -and $tenStateAfterDirect.Text.Contains('WRITES=0')
$tenBypass = $tenCrafted.Status -eq 200 -and $tenCrafted.Text.Contains('MARKER=PROTECTED_READ;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp;FRAMEWORK=.NET 10.0.15')
$tenStatic = $tenStaticCrafted.Status -eq 200 -and $tenStaticCrafted.Text.Contains('STATIC_PROTECTED_CONTENT_04')
$tenEffect = $tenPostCrafted.Status -eq 200 -and $tenPostCrafted.Text.Contains('MARKER=PROTECTED_WRITE;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp;FRAMEWORK=.NET 10.0.15') -and $tenStateAfterCrafted.Text.Contains('WRITES=1')
Note "TEN_BASELINE=$tenBaseline TEN_GUARD=$tenGuard TEN_DIRECT_WRITE_BLOCKED=$tenDirectWriteBlocked TEN_BYPASS=$tenBypass TEN_STATIC=$tenStatic TEN_EFFECT=$tenEffect"
Require $tenBaseline '.NET 10.0.15 in-process baseline failed'
Require $tenGuard '.NET 10.0.15 direct IP guard failed'
Require $tenDirectWriteBlocked '.NET 10.0.15 direct write was not blocked'
Require $tenBypass '.NET 10.0.15 crafted route bypass failed'
Require $tenStatic '.NET 10.0.15 static file bypass failed'
Require $tenEffect '.NET 10.0.15 protected write bypass failed'
Note 'LAB04_10_0_15_PASS'

$authPublish = Join-Path $env:RUNNER_TEMP 'hunt04-auth-publish'
New-Item -ItemType Directory -Path $authPublish -Force | Out-Null
Copy-Item -Path (Join-Path $publish '*') -Destination $authPublish -Recurse -Force
$roleLocation = @'
  <location path="Admin">
    <system.webServer>
      <security>
        <authorization>
          <clear />
          <add accessType="Allow" roles="BUILTIN\Administrators" />
        </authorization>
      </security>
    </system.webServer>
  </location>
'@
$authConfig = $ipConfig.Replace('</configuration>', $roleLocation + "`r`n</configuration>")
Set-Content -Path (Join-Path $authPublish 'web.config') -Encoding utf8 -Value $authConfig
New-WebAppPool -Name 'Hunt04AuthPool' | Out-Null
Set-ItemProperty 'IIS:\AppPools\Hunt04AuthPool' -Name managedRuntimeVersion -Value ''
New-Website -Name 'Hunt04AuthLab' -Port 5089 -IPAddress '127.0.0.1' -PhysicalPath $authPublish -ApplicationPool 'Hunt04AuthPool' | Out-Null
& $appcmd set config 'Hunt04AuthLab/Admin' -section:system.webServer/security/authentication/anonymousAuthentication '/enabled:false' '/commit:apphost'
Require ($LASTEXITCODE -eq 0) 'Could not disable anonymous auth under Admin'
& $appcmd set config 'Hunt04AuthLab/Admin' -section:system.webServer/security/authentication/windowsAuthentication '/enabled:true' '/commit:apphost'
Require ($LASTEXITCODE -eq 0) 'Could not enable Windows auth under Admin'
Note 'IIS_WINDOWS_AUTH_CONFIG_START'
& $appcmd list config 'Hunt04AuthLab/Admin' -section:system.webServer/security/authentication/anonymousAuthentication
& $appcmd list config 'Hunt04AuthLab/Admin' -section:system.webServer/security/authentication/windowsAuthentication
& $appcmd list config 'Hunt04AuthLab/Admin' -section:system.webServer/security/authorization
Require ($LASTEXITCODE -eq 0) 'IIS did not load the Admin role authorization config'
Note 'IIS_WINDOWS_AUTH_CONFIG_END'

$authPublic = Send-Raw 'GET' '/Delete' 5089
$authDirect = Send-Raw 'GET' '/Admin/Delete' 5089
$authStaticDirect = Send-Raw 'GET' '/Admin/secret.txt' 5089
$authStateBefore = Send-Raw 'GET' '/State' 5089
$authPostDirect = Send-Raw 'POST' '/Admin/Delete' 5089
$authStateAfterDirect = Send-Raw 'GET' '/State' 5089
$validAdmin = $false
try {
    $adminResponse = Invoke-WebRequest -Uri 'http://127.0.0.1:5089/Admin/Delete' -UseDefaultCredentials -UseBasicParsing -TimeoutSec 20
    Note "AUTHENTICATED_ADMIN status=$([int]$adminResponse.StatusCode) body=$($adminResponse.Content)"
    $validAdmin = $adminResponse.StatusCode -eq 200 -and $adminResponse.Content.Contains('MARKER=PROTECTED_READ') -and $adminResponse.Content.Contains('AUTH=True')
} catch {
    Note "AUTHENTICATED_ADMIN_ERROR=$($_.Exception.Message)"
}
$authCrafted = Send-Raw 'GET' '/Admin//../Delete' 5089
$authStaticCrafted = Send-Raw 'GET' '/Admin//../secret.txt' 5089
$authPostCrafted = Send-Raw 'POST' '/Admin//../Delete' 5089
$authStateAfterCrafted = Send-Raw 'GET' '/State' 5089
$authBaseline = $authPublic.Status -eq 200 -and $authPublic.Text.Contains('MARKER=PUBLIC') -and $authPublic.Text.Contains('PROCESS=w3wp')
$authGuard = $authDirect.Status -eq 401 -and $authStaticDirect.Status -eq 401 -and $authPostDirect.Status -eq 401
$authDirectWriteBlocked = $authStateBefore.Text.Contains('WRITES=0') -and $authStateAfterDirect.Text.Contains('WRITES=0')
$authBypass = $authCrafted.Status -eq 200 -and $authCrafted.Text.Contains('MARKER=PROTECTED_READ;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp') -and $authCrafted.Text.Contains('AUTH=False')
$authStatic = $authStaticCrafted.Status -eq 200 -and $authStaticCrafted.Text.Contains('STATIC_PROTECTED_CONTENT_04')
$authEffect = $authPostCrafted.Status -eq 200 -and $authPostCrafted.Text.Contains('MARKER=PROTECTED_WRITE;PATH=/Admin/Delete;RAW=/Admin//../Delete;PROCESS=w3wp') -and $authPostCrafted.Text.Contains('AUTH=False') -and $authStateAfterCrafted.Text.Contains('WRITES=1')
Note "AUTH_BASELINE=$authBaseline AUTH_GUARD=$authGuard AUTH_DIRECT_WRITE_BLOCKED=$authDirectWriteBlocked AUTH_ADMIN_POSITIVE=$validAdmin AUTH_BYPASS=$authBypass AUTH_STATIC=$authStatic AUTH_EFFECT=$authEffect"
Require $authBaseline 'Windows auth public baseline failed'
Require $authGuard 'Windows auth / admin role did not deny unauthenticated direct paths'
Require $authDirectWriteBlocked 'Unauthenticated direct POST changed admin state'
Require $validAdmin 'Valid local administrator could not reach the protected route'
Require $authBypass 'Unauthenticated crafted path did not reach admin route'
Require $authStatic 'Unauthenticated crafted path did not disclose admin static file'
Require $authEffect 'Unauthenticated crafted path did not change admin state'
Note 'LAB04_FULL_CHAIN_PASS'
