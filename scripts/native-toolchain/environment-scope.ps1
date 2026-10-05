function Restore-ProcessEnvironment([hashtable]$Previous) {
  foreach($name in $Previous.Keys) {
    if($null -eq $Previous[$name]) {
      # PowerShell's overload binding can turn null into an empty string. On
      # modern .NET that leaves an existing empty environment variable.
      Remove-Item -LiteralPath ('Env:'+ $name) -ErrorAction SilentlyContinue
    } else {
      [Environment]::SetEnvironmentVariable($name,[string]$Previous[$name],'Process')
    }
  }
}
