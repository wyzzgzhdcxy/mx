# Pre-create plugin symlinks (as junctions) for all desktop platforms.
#
# Why: Flutter's _createPlatformPluginSymlinks calls link.createSync when
# link.existsSync() is false. On this machine that call intermittently fails with
# PathNotFoundException / PathExistsException, which aborts `flutter build`.
# Pre-creating the links makes existsSync() return true and Flutter skips the
# create step entirely.
#
# Junctions are used instead of SymbolicLink because creating directory symlinks
# on Windows requires admin rights or Developer Mode, while junctions do not.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\mklinks.ps1
#
param(
  [string]$ProjectDir = 'D:\code\mx'
)

$ErrorActionPreference = 'Stop'

$depFile = Join-Path $ProjectDir '.flutter-plugins-dependencies'
if (-not (Test-Path $depFile)) { throw "Missing $depFile - run flutter pub get first" }

$json = Get-Content $depFile -Raw -Encoding UTF8 | ConvertFrom-Json

$log = @()
foreach ($platform in @('windows', 'linux')) {
  $plugins = $json.plugins.$platform
  if (-not $plugins) { $log += ("[" + $platform + "] no plugins"); continue }

  $sl = Join-Path $ProjectDir ($platform + '\flutter\ephemeral\.plugin_symlinks')
  New-Item -ItemType Directory -Force -Path $sl | Out-Null
  $log += ("[" + $platform + "] " + $sl)

  foreach ($p in $plugins) {
    $name = $p.name
    $target = $p.path.TrimEnd('\')
    $link = Join-Path $sl $name

    if (-not (Test-Path $target)) { $log += ("  SKIP " + $name + " (no target)"); continue }

    if (Test-Path $link) {
      $item = Get-Item $link -Force -ErrorAction SilentlyContinue
      if ($item -and ($item.LinkType -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $log += ("  KEEP " + $name)
        continue
      }
      # A plain directory left over from a failed ln -s: remove and redo.
      Remove-Item $link -Recurse -Force -ErrorAction SilentlyContinue
    }

    try {
      New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
      $log += ("  JUNC " + $name)
    } catch {
      $log += ("  FAIL " + $name + " : " + $_.Exception.Message)
    }
  }
}
$log -join "`n"
