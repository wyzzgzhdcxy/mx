<#
.SYNOPSIS
    密信（Mx）全平台发布包构建脚本。

.DESCRIPTION
    依次构建 Windows / Android / Web，把产物统一收集到仓库根的 dist\ 目录，
    便于一次性取出所有平台的程序包。

    Linux 产物需要在 Linux 环境（或 WSL / 容器）里用 `flutter build linux --release`
    构建，脚本检测到非 Linux 环境会跳过并给出提示。

.PARAMETER Only
    只构建指定平台：windows / android / web / linux。不指定则构建全部可用平台。

.PARAMETER SkipWeb
    跳过 Web 构建（Web 构建耗时较长，且产物与桌面端是两套运行时）。

.PARAMETER SplitAbi
    Android 按 ABI 拆分 APK（体积更小，但会产出多个包）。
    默认产出单个通用 APK，方便直接安装。

.EXAMPLE
    .\scripts\build-release.ps1
    构建全部平台并收集到 dist\

.EXAMPLE
    .\scripts\build-release.ps1 -Only android
    只构建 Android APK
#>

[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'web', 'linux', '')]
    [string]$Only = '',

    [switch]$SkipWeb,

    [switch]$SplitAbi
)

$ErrorActionPreference = 'Stop'

# --- 路径与工具定位 ---------------------------------------------------------

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DistDir = Join-Path $RepoRoot 'dist'
$FlutterBin = 'E:\application\flutter\bin\flutter.bat'

if (-not (Test-Path $FlutterBin)) {
    # 兜底：从 PATH 里找
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) {
        $FlutterBin = $cmd.Source
    } else {
        throw "找不到 Flutter：既不在 $FlutterBin，也不在 PATH 上。请先安装 Flutter SDK。"
    }
}

function Write-Step($msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Invoke-Flutter([string[]]$Args) {
    Write-Host "    flutter $($Args -join ' ')" -ForegroundColor DarkGray
    & $FlutterBin @Args
    if ($LASTEXITCODE -ne 0) {
        throw "构建失败：flutter $($Args -join ' ') 退出码 $LASTEXITCODE"
    }
}

function Copy-ToDist([string]$Source, [string]$TargetSub) {
    if (-not (Test-Path $Source)) {
        Write-Host "    跳过（产物不存在）：$Source" -ForegroundColor Yellow
        return
    }
    $target = Join-Path $DistDir $TargetSub
    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item $Source -Destination $target -Recurse -Force
    $size = (Get-ChildItem $target -Recurse -File |
        Measure-Object -Property Length -Sum).Sum
    Write-Host "    -> dist\$TargetSub  ($([math]::Round($size / 1MB, 1)) MB)" -ForegroundColor Green
}

# 预建插件链接。
#
# 必须在 flutter build 之前跑：Flutter 的 _createPlatformPluginSymlinks 在
# link.existsSync() 为 false 时会调 createSync，而在本机环境下这一步会间歇性抛
# PathNotFoundException / PathExistsException，直接把构建打断。提前把链接建好，
# existsSync() 命中，Flutter 就会跳过创建。
function Initialize-PluginLinks {
    $depFile = Join-Path $RepoRoot '.flutter-plugins-dependencies'
    if (-not (Test-Path $depFile)) { return }

    $json = Get-Content $depFile -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($platform in @('windows', 'linux')) {
        $plugins = $json.plugins.$platform
        if (-not $plugins) { continue }

        $sl = Join-Path $RepoRoot "$platform\flutter\ephemeral\.plugin_symlinks"
        New-Item -ItemType Directory -Force -Path $sl | Out-Null

        foreach ($p in $plugins) {
            $target = $p.path.TrimEnd('\')
            $link = Join-Path $sl $p.name
            if (-not (Test-Path $target)) { continue }

            if (Test-Path $link) {
                $item = Get-Item $link -Force -ErrorAction SilentlyContinue
                if ($item -and ($item.LinkType -or
                        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
                    continue
                }
                Remove-Item $link -Recurse -Force -ErrorAction SilentlyContinue
            }
            # junction 而非 symlink：Windows 上创建目录符号链接需要管理员权限或
            # 开发者模式，junction 不需要。
            New-Item -ItemType Junction -Path $link -Target $target -ErrorAction SilentlyContinue |
                Out-Null
        }
    }
    Write-Host '    插件链接已就绪' -ForegroundColor DarkGray
}

# 删除 Web 产物里的 .symbols 调试符号文件。
#
# 这些是 wasm/js 的符号表，只在分析崩溃栈时有用，运行时完全不加载
# （全量扫描产物内所有 .js 后确认无任何引用）。删掉可直接省约 8 MB。
#
# 注意：只删 .symbols，不动 canvaskit 下的多渲染器变体
# （chromium/、webparagraph/、skwasm*、wimp）——那些是运行时按浏览器能力
# 动态选择的，删了会让部分浏览器白屏。
function Remove-WebSymbols([string]$WebRoot) {
    if (-not (Test-Path $WebRoot)) { return }

    $symbols = Get-ChildItem $WebRoot -Recurse -File -Filter '*.symbols' -ErrorAction SilentlyContinue
    if (-not $symbols) {
        Write-Host '    无符号文件可删' -ForegroundColor DarkGray
        return
    }

    $freed = 0
    foreach ($f in $symbols) {
        $freed += $f.Length
        Remove-Item $f.FullName -Force
    }
    Write-Host ("    删除 {0} 个符号文件，省 {1} MB" -f `
        $symbols.Count, [math]::Round($freed / 1MB, 2)) -ForegroundColor Green
}

# 读取 APK 里实际打进去的 ABI 列表，用于构建日志核对体积优化是否生效。
#
# 注意：Flutter 的 --target-platform 只控制 Flutter 引擎自己的 .so；
# 第三方插件的 native 库若未声明 ABI 过滤，其 x86_64 变体仍会被打进来
# （本项目实测残留 0.1 MB，可忽略）。所以这里要把真实结果打出来，
# 而不是假定参数写对了就等于包是对的。
function Get-ApkAbis([string]$ApkPath) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
        try {
            $abis = $zip.Entries |
                Where-Object { $_.FullName -like 'lib/*' } |
                ForEach-Object { ($_.FullName -split '/')[1] } |
                Sort-Object -Unique
            if ($abis) { return ($abis -join '+') }
            return '无 native 库'
        } finally {
            $zip.Dispose()
        }
    } catch {
        return 'ABI 未知'
    }
}

# --- 开始 -------------------------------------------------------------------

Write-Host '密信（Mx）全平台构建' -ForegroundColor Green
Write-Host "仓库：$RepoRoot"
Write-Host "Flutter：$FlutterBin"

Push-Location $RepoRoot
try {
    # 国内网络下 pub 直连较慢，走镜像
    if (-not $env:PUB_HOSTED_URL) {
        $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    }
    if (-not $env:FLUTTER_STORAGE_BASE_URL) {
        $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    }

    Write-Step '拉取依赖'
    Invoke-Flutter @('pub', 'get')

    Write-Step '准备插件链接'
    Initialize-PluginLinks

    $doWindows = ($Only -eq '' -or $Only -eq 'windows') -and $IsWindows
    $doAndroid = ($Only -eq '' -or $Only -eq 'android')
    $doWeb = ($Only -eq '' -or $Only -eq 'web') -and (-not $SkipWeb)
    $doLinux = ($Only -eq 'linux') -or ($Only -eq '' -and -not $IsWindows)

    # --- Windows ---
    if ($doWindows) {
        Write-Step '构建 Windows Release'
        Invoke-Flutter @('build', 'windows', '--release')
        Copy-ToDist (Join-Path $RepoRoot 'build\windows\x64\runner\Release') 'windows'
    } elseif ($Only -eq 'windows') {
        Write-Host '跳过 Windows：非 Windows 环境无法构建 Windows 产物。' -ForegroundColor Yellow
    }

    # --- Android ---
    if ($doAndroid) {
        Write-Step '构建 Android Release APK'
        # --target-platform 只出 ARM，剔除 x86_64 的 Flutter 引擎库（约 18 MB）。
        #
        # 用 Flutter 参数而不是在 build.gradle.kts 里写 abiFilters/splits：
        # 后者会和 --split-per-abi 互相干扰，导致产物错乱。
        #
        # 注意 --target-platform 管不到第三方插件的 native 库，其 x86_64 变体会
        # 残留（本项目实测约 0.1 MB），可忽略。
        if ($SplitAbi) {
            Invoke-Flutter @(
                'build', 'apk', '--release', '--split-per-abi',
                '--target-platform', 'android-arm,android-arm64'
            )
        } else {
            Invoke-Flutter @(
                'build', 'apk', '--release',
                '--target-platform', 'android-arm,android-arm64'
            )
        }
        # split-per-abi 与通用 APK 的产物目录不同，逐个文件拷
        $apkDir = Join-Path $RepoRoot 'build\app\outputs\flutter-apk'
        if (Test-Path $apkDir) {
            $target = Join-Path $DistDir 'android'
            if (Test-Path $target) { Remove-Item $target -Recurse -Force }
            New-Item -ItemType Directory -Path $target -Force | Out-Null

            # 先清掉上一次构建的旧包，否则改过参数后新旧 APK 会一起留在目录里，
            # 分不清哪个才是本次产物。
            Get-ChildItem $apkDir -Filter '*.apk' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $age = (Get-Date) - $_.LastWriteTime
                    if ($age.TotalMinutes -gt 30) { Remove-Item $_.FullName -Force }
                }

            Get-ChildItem $apkDir -Filter '*.apk' | Sort-Object Name | ForEach-Object {
                # 产物名统一加上可读后缀，避免一堆 app-*-release.apk 难以分辨
                $newName = $_.Name -replace '^app-', '密信-'
                Copy-Item $_.FullName -Destination (Join-Path $target $newName) -Force
                $mb = [math]::Round($_.Length / 1MB, 1)
                $abis = Get-ApkAbis $_.FullName
                Write-Host "    -> dist\android\$newName  ($mb MB, $abis)" -ForegroundColor Green
            }
        }
    }

    # --- Web ---
    if ($doWeb) {
        Write-Step '构建 Web Release'
        # --no-wasm-dry-run：跳过 wasm 兼容性预检，省一次完整编译。
        # 本项目用的是 canvaskit 渲染器（见 flutter_bootstrap.js 的 renderer 字段），
        # 不依赖 wasm 运行时，这个预检对我们没有产出价值。
        Invoke-Flutter @('build', 'web', '--release', '--no-wasm-dry-run')

        Write-Step '裁剪 Web 调试符号'
        Remove-WebSymbols (Join-Path $RepoRoot 'build\web')
        Copy-ToDist (Join-Path $RepoRoot 'build\web') 'web'
    }

    # --- Linux ---
    if ($doLinux) {
        Write-Step '构建 Linux Release'
        Invoke-Flutter @('build', 'linux', '--release')
        Copy-ToDist (Join-Path $RepoRoot 'build\linux\x64\release\bundle') 'linux'
    } elseif ($Only -eq '') {
        Write-Host ''
        Write-Host '提示：Linux 产物需要在 Linux 环境构建。' -ForegroundColor Yellow
        Write-Host '      在 Linux 上执行： flutter build linux --release' -ForegroundColor Yellow
    }

    # --- 汇总 ---
    Write-Step '构建完成，产物清单'
    if (Test-Path $DistDir) {
        Get-ChildItem $DistDir -Directory | ForEach-Object {
            $files = Get-ChildItem $_.FullName -Recurse -File
            $size = ($files | Measure-Object -Property Length -Sum).Sum
            Write-Host ("  {0,-10} {1,6} 个文件  {2,8} MB" -f `
                $_.Name, $files.Count, [math]::Round($size / 1MB, 1))
        }
        Write-Host ''
        Write-Host "产物目录： $DistDir" -ForegroundColor Green
    } else {
        Write-Host '没有产出任何包。' -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}
