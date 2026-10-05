$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$distribution = 'gradle-9.3.1-all.zip'
$url = 'https://services.gradle.org/distributions/' + $distribution
$expectedSha256 = '17f277867f6914d61b1aa02efab1ba7bb439ad652ca485cd8ca6842fccec6e43'
$downloads = Join-Path $workspace '.tools/downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$archive = Join-Path $downloads $distribution
if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSha256) {
  & curl.exe --silent --show-error --fail --location --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 1800 --continue-at - --output $archive $url
  if ($LASTEXITCODE -ne 0) { throw "Official Gradle distribution download failed: curl exit $LASTEXITCODE" }
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSha256) { throw 'Official Gradle distribution SHA256 mismatch.' }
# Gradle's wrapper uses MD5 of the distribution URL as a base-36 cache key.
# The content is authenticated separately with the official SHA256 above.
Add-Type -AssemblyName System.Numerics
$md5 = [Security.Cryptography.MD5]::Create()
try { $urlHash = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($url)) } finally { $md5.Dispose() }
$number = [Numerics.BigInteger]::Zero
foreach ($byte in $urlHash) { $number = $number * 256 + $byte }
$digits = '0123456789abcdefghijklmnopqrstuvwxyz'
$cacheKey = ''
while ($number -gt 0) {
  $cacheKey = $digits[[int]($number % 36)] + $cacheKey
  $number = [Numerics.BigInteger]::Divide($number,[Numerics.BigInteger]36)
}
$cache = Join-Path $workspace ('.tools/gradle-cache/wrapper/dists/gradle-9.3.1-all/' + $cacheKey)
New-Item -ItemType Directory -Force -Path $cache | Out-Null
Copy-Item -LiteralPath $archive -Destination (Join-Path $cache $distribution) -Force
Write-Host "Verified official Gradle distribution cached: $cache"
$global:LASTEXITCODE = 0
