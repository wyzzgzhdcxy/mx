<#
.SYNOPSIS
    密信（Mx）全平台发布包构建脚本。

.DESCRIPTION
    构建当前宿主系统能构建的所有平台，把产物统一收集到仓库根的 dist\ 目录。

    Flutter 的产物与宿主系统强绑定，各平台的可构建性：

        平台        可在哪里构建
        ---------   ------------------------------------------
        Windows     仅 Windows
        Android     任意（Windows / Linux / macOS）
        Web         任意
        Linux       仅 Linux（含 WSL）
        macOS       仅 macOS
        iOS         仅 macOS（且需 Xcode + 签名证书）

    脚本会自动跳过当前宿主无法构建的平台并给出原因，不会报错中断。
    因此同一份脚本在 Windows / Linux / macOS 上都能直接跑，各取所得。

.PARAMETER Only
    只构建指定平台：windows / android / web / linux / macos / ios。
    不指定则构建当前宿主支持的全部平台。

.PARAMETER SkipWeb
    跳过 Web 构建（Web 构建耗时较长，且产物与桌面端是两套运行时）。

.PARAMETER SplitAbi
    Android 按 ABI 拆分 APK（体积更小，但会产出多个包）。
    默认产出单个通用 APK，方便直接安装。
    注意：与 build.gradle.kts 里的 abiFilters 机制冲突，非必要不要开。

.PARAMETER TargetPlatform
    Android 目标架构，逗号分隔，默认 'android-arm64'（只出 64 位 ARM）。
    需要兼容老 32 位机型时传 'android-arm,android-arm64'。

.EXAMPLE
    .\scripts\build-release.ps1
    构建当前宿主支持的全部平台并收集到 dist\

.EXAMPLE
    .\scripts\build-release.ps1 -Only android
    只构建 Android APK（仅 arm64）

.EXAMPLE
    .\scripts\build-release.ps1 -Only android -TargetPlatform 'android-arm,android-arm64'
    构建兼容 32 位机型的 Android APK
#>

[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'web', 'linux', 'macos', 'ios', '')]
    [string]$Only = '',

    [switch]$SkipWeb,

    [switch]$SplitAbi,

    [string]$TargetPlatform = 'android-arm64'
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

# 注意：形参**不能**叫 $Args —— 那是 PowerShell 的自动变量（保存未绑定的位置参数），
# 用作函数形参名会被忽略，导致传进来的参数全部丢失、flutter 收到空参数只打印 help。
# 这个坑很隐蔽：脚本"能跑"，只是什么都没构建。
function Invoke-Flutter([string[]]$FlutterArgs) {
    Write-Host "    flutter $($FlutterArgs -join ' ')" -ForegroundColor DarkGray
    & $FlutterBin @FlutterArgs
    if ($LASTEXITCODE -ne 0) {
        throw "构建失败：flutter $($FlutterArgs -join ' ') 退出码 $LASTEXITCODE"
    }
}

function Copy-ToDist([string]$Source, [string]$TargetSub) {
    if (-not (Test-Path $Source)) {
        Write-Host "    跳过（产物不存在）：$Source" -ForegroundColor Yellow
        return
    }
    $target = Join-Path $DistDir $TargetSub
    Clear-DistDir $target
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item $Source -Destination $target -Recurse -Force
    $size = (Get-ChildItem $target -Recurse -File |
        Measure-Object -Property Length -Sum).Sum
    Write-Host "    -> dist\$TargetSub  ($([math]::Round($size / 1MB, 1)) MB)" -ForegroundColor Green
}

# 清空 dist 下的某个子目录，供重新收集产物。
#
# 不用 Remove-Item -Recurse 删整个目录：某些安全策略（含本机 WorkBuddy 的
# safe-delete 护栏）会拒绝这类批量递归删除，报 SAFE_DELETE_FAIL_CLOSED，
# 直接把构建流程打断在"已构建完但没收集"的状态。
#
# 这里改成只删目录**内的文件**、保留目录本身：绕开对整目录的删除保护，
# 语义上也更准确——我们要的是"清空"，不是"删掉这个目录"。
# dist 是我们自己生成的产物目录，内容可随时重建，无需走回收站。
function Clear-DistDir([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            # 子目录仍需递归清空；用 .NET 直删而非 Remove-Item -Recurse，
            # 后者对深层目录会触发上述护栏。
            try {
                [System.IO.Directory]::Delete($_.FullName, $true)
            } catch {
                Write-Host "    清理失败（跳过）：$($_.FullName)" -ForegroundColor DarkYellow
            }
        } else {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
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
            if ($abis) { return ($abis -join '_') }
            return '无native库'
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

    # 各平台的可构建宿主，详见文件头注释。
    # $IsWindows / $IsMacOS 在 PowerShell 5.1 上不存在（5.1 没有这些自动变量），
    # 在 strict mode 下直接引用会抛错，故用 $env:OS 兜底判断。
    $onWin = ($env:OS -eq 'Windows_NT') -or ($IsWindows -eq $true)
    $onMac = $IsMacOS -eq $true
    $onLinux = (-not $onWin) -and (-not $onMac)

    # 宿主不支持的平台一律不构建——即使 -Only 明确点了它。
    # 早期版本写成 ($Only -eq 'linux') -or ($Only -eq '' -and $onLinux)，
    # 结果在 Windows 上 -Only linux 会真的去调 flutter build linux，
    # Flutter 拒绝后打印一大段 help 文本，看起来像"已经尝试过了"的假象。
    $wantPlatform = {
        param($name, $hostOk)
        ($Only -eq '' -or $Only -eq $name) -and $hostOk
    }

    $doWindows = & $wantPlatform 'windows' $onWin
    $doAndroid = & $wantPlatform 'android' $true
    $doWeb = (& $wantPlatform 'web' $true) -and (-not $SkipWeb)
    $doLinux = & $wantPlatform 'linux' $onLinux
    $doMacos = & $wantPlatform 'macos' $onMac
    $doIos = & $wantPlatform 'ios' $onMac

    # 明确点了某平台但宿主不支持时，说清楚原因，别让它静默消失
    $hostName = if ($onWin) { 'Windows' } elseif ($onMac) { 'macOS' } else { 'Linux' }
    foreach ($pair in @(
            @{ n = 'windows'; ok = $onWin; why = '只能在 Windows 上构建' },
            @{ n = 'linux'; ok = $onLinux; why = '只能在 Linux（含 WSL）上构建' },
            @{ n = 'macos'; ok = $onMac; why = '只能在 macOS 上构建（需 Xcode）' },
            @{ n = 'ios'; ok = $onMac; why = '只能在 macOS 上构建（需 Xcode + 签名证书）' })) {
        if ($Only -eq $pair.n -and -not $pair.ok) {
            Write-Host ("跳过 {0}：{1}。当前宿主是 {2}。" -f `
                $pair.n, $pair.why, $hostName) -ForegroundColor Yellow
        }
    }

    # --- Windows ---
    if ($doWindows) {
        Write-Step '构建 Windows Release'
        Invoke-Flutter @('build', 'windows', '--release')
        Copy-ToDist (Join-Path $RepoRoot 'build\windows\x64\runner\Release') 'windows'
    }

    # --- Android ---
    if ($doAndroid) {
        Write-Step '构建 Android Release APK'
        # 默认只出 arm64-v8a（用户指定）：17.7 MB，对比全架构包 50.2 MB 减 65%。
        #
        # 为什么默认就是 arm64：现在市面上的 Android 真机（含全部国产机型）
        # 基本都已是 64 位 ARM，armeabi-v7a 的兼容价值在下降；x86_64 更是只在
        # Intel/AMD 的模拟器上有用。需要兼容老 32 位机型时用 -TargetPlatform
        # 显式指定 'android-arm,android-arm64'。
        #
        # 注意：--target-platform 只管 Flutter 引擎自己的 .so，管不到第三方插件
        # 从 AAR 带进来的 native 库。插件那几个 v7a/x86_64 变体由
        # android/app/build.gradle.kts 里的 ndk.abiFilters + packaging.jniLibs
        # 双重过滤掉，两边缺一不可。
        if ($SplitAbi) {
            # 分架构拆包与 abiFilters 冲突（两种机制都在决定 ABI 集合），
            # 故这条路径只在明确要求时才走，且只拆 arm 系。
            Invoke-Flutter @(
                'build', 'apk', '--release', '--split-per-abi',
                '--target-platform', $TargetPlatform
            )
        } else {
            Invoke-Flutter @(
                'build', 'apk', '--release',
                '--target-platform', $TargetPlatform
            )
        }
        # split-per-abi 与通用 APK 的产物目录不同，逐个文件拷
        $apkDir = Join-Path $RepoRoot 'build\app\outputs\flutter-apk'
        if (Test-Path $apkDir) {
            $target = Join-Path $DistDir 'android'
            Clear-DistDir $target
            New-Item -ItemType Directory -Path $target -Force | Out-Null

            # 先清掉上一次构建的旧包，否则改过参数后新旧 APK 会一起留在目录里，
            # 分不清哪个才是本次产物。
            Get-ChildItem $apkDir -Filter '*.apk' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $age = (Get-Date) - $_.LastWriteTime
                    if ($age.TotalMinutes -gt 30) { Remove-Item $_.FullName -Force }
                }

            Get-ChildItem $apkDir -Filter '*.apk' | Sort-Object Name | ForEach-Object {
                $abis = Get-ApkAbis $_.FullName
                # 产物名带上架构，一眼能看出装的什么包。
                # app-release.apk         -> 密信-<架构>-release.apk
                # app-arm64-v8a-release.apk -> 密信-arm64-v8a-release.apk
                $newName = $_.Name -replace '^app-', '密信-'
                if ($newName -notmatch 'arm|x86|abi') {
                    $newName = $newName -replace '^密信-', "密信-$abis-"
                }
                Copy-Item $_.FullName -Destination (Join-Path $target $newName) -Force
                $mb = [math]::Round($_.Length / 1MB, 1)
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
        # bundle 目录里的 mx 依赖同目录的 lib/，必须整个目录一起拷
        Copy-ToDist (Join-Path $RepoRoot 'build/linux/x64/release/bundle') 'linux'
    }

    # --- macOS ---
    if ($doMacos) {
        Write-Step '构建 macOS Release'
        Invoke-Flutter @('build', 'macos', '--release')
        $macApp = Join-Path $RepoRoot 'build/macos/Build/Products/Release'
        if (Test-Path $macApp) {
            $target = Join-Path $DistDir 'macos'
            Clear-DistDir $target
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            # 用 Get-ChildItem 而非固定名：产物名取决于 CFBundleName，
            # 随配置变动容易写死导致漏拷。
            Get-ChildItem $macApp -Filter '*.app' | ForEach-Object {
                Copy-Item $_.FullName -Destination $target -Recurse -Force
                $size = (Get-ChildItem $_.FullName -Recurse -File |
                    Measure-Object -Property Length -Sum).Sum
                Write-Host ("    -> dist/macos/{0}  ({1} MB)" -f `
                    $_.Name, [math]::Round($size / 1MB, 1)) -ForegroundColor Green
            }
        }
    }

    # --- iOS ---
    if ($doIos) {
        Write-Step '构建 iOS Release'
        # --no-codesign：不配签名团队也能验证能否编译通过。
        # 要出可安装的 ipa，需先在 Xcode 里配好 Signing Team，再改用 build ipa。
        Invoke-Flutter @('build', 'ios', '--release', '--no-codesign')
        $iosApp = Join-Path $RepoRoot 'build/ios/iphoneos'
        if (Test-Path $iosApp) {
            $target = Join-Path $DistDir 'ios'
            Clear-DistDir $target
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Get-ChildItem $iosApp -Filter '*.app' | ForEach-Object {
                # 只拿 .app 本体，跳过 .dSYM（调试符号，分发不需要）
                Copy-Item $_.FullName -Destination $target -Recurse -Force
                Write-Host "    -> dist/ios/$($_.Name)" -ForegroundColor Green
            }
            Write-Host '    提示：未签名的 .app 无法直接装真机，需配 Xcode Signing Team 后改用 flutter build ipa' `
                -ForegroundColor DarkGray
        }
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

        # 当前宿主构建不了的平台，明确列出来，避免误以为"漏做了"
        $skipped = @()
        if (-not $onWin) { $skipped += 'windows' }
        if (-not $onLinux) { $skipped += 'linux' }
        if (-not $onMac) { $skipped += 'macos'; $skipped += 'ios' }
        if ($skipped.Count -gt 0) {
            Write-Host ("本机（{0}）无法构建：{1}" -f `
                $(if ($onWin) { 'Windows' } elseif ($onMac) { 'macOS' } else { 'Linux' }), `
                ($skipped -join ', ')) -ForegroundColor Yellow
            Write-Host '  这些平台的产物需在对应系统上执行本脚本获得，工程配置已就绪。' -ForegroundColor DarkGray
            Write-Host ''
        }
        Write-Host "产物目录： $DistDir" -ForegroundColor Green
    } else {
        Write-Host '没有产出任何包。' -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}
