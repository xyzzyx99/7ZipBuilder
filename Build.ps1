param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string] $BuildVersion
)

$workDir = $PSScriptRoot
$buildDir = "$workDir\$BuildVersion"
$tempDir = "$workDir\Temp"

$currentDir = Get-Location

function Update-7ZipBuildOptimization {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BuildDirectory
    )

    $buildMak = Join-Path $BuildDirectory "CPP\Build.mak"
    if (-not (Test-Path $buildMak)) {
        throw "Cannot find 7-Zip makefile: $buildMak"
    }

    # 7-Zip's makefiles compile different targets through CFLAGS_O1 and CFLAGS_O2.
    # Patch both so no target is left using the default -O1 path.
    $optFlags = '$(CFLAGS) -O2 -Ob3 -Oi -Ot -Oy -GL -Gy -GF -Gw -arch:AVX2'
    $linkFlags = @('-LTCG', '-OPT:REF', '-OPT:ICF')

    $lines = Get-Content -Path $buildMak
    $seenCFlagsO1 = $false
    $seenCFlagsO2 = $false
    $seenLFlags = $false

    $updatedLines = foreach ($line in $lines) {
        if ($line -match '^\s*CFLAGS_O1\s*=') {
            $seenCFlagsO1 = $true
            "CFLAGS_O1 = $optFlags"
        }
        elseif ($line -match '^\s*CFLAGS_O2\s*=') {
            $seenCFlagsO2 = $true
            "CFLAGS_O2 = $optFlags"
        }
        elseif ($line -match '^\s*LFLAGS\s*=') {
            $seenLFlags = $true
            $newLine = $line
            foreach ($flag in $linkFlags) {
                if ($newLine -notmatch [regex]::Escape($flag)) {
                    $newLine += " $flag"
                }
            }
            $newLine
        }
        else {
            $line
        }
    }

    if (-not $seenCFlagsO1) {
        $updatedLines += "CFLAGS_O1 = $optFlags"
    }
    if (-not $seenCFlagsO2) {
        $updatedLines += "CFLAGS_O2 = $optFlags"
    }
    if (-not $seenLFlags) {
        $updatedLines += 'LFLAGS = -LTCG -OPT:REF -OPT:ICF'
    }

    Set-Content -Path $buildMak -Value $updatedLines -Encoding UTF8

    Write-Output "Patched 7-Zip compiler/linker optimization flags in $buildMak"
    Select-String -Path $buildMak -Pattern 'CFLAGS_O1|CFLAGS_O2|LFLAGS|arch:AVX2|LTCG' | ForEach-Object {
        Write-Output $_.Line
    }
}

if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir
}

# 下载并解压VsWhere
if (-not (Test-Path "$tempDir\VsWhere")) {
    if (-not (Test-Path "$tempDir\vswhere.zip")) {
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/vswhere" -OutFile "$tempDir\vswhere.zip"
    }
    Expand-Archive -Path "$tempDir\vswhere.zip" -DestinationPath "$tempDir\VsWhere"
}

# 查找并进入x64编译环境
$vsInstallPath = & "$tempDir\VsWhere\tools\vswhere.exe" -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Import-Module "$vsInstallPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vsInstallPath -DevCmdArguments "-arch=amd64 -host_arch=amd64" -SkipAutomaticLocation

# 使用 AVX2 和最大优化编译7-Zip本体及其安装卸载程序
Update-7ZipBuildOptimization -BuildDirectory $buildDir

Set-Location "$buildDir\CPP\7zip"
& nmake PLATFORM=x64
Set-Location "$buildDir\C\Util\7zipInstall"
& nmake PLATFORM=x64
Set-Location "$buildDir\C\Util\7zipUninstall"
& nmake PLATFORM=x64

# 进入x86编译环境
Enter-VsDevShell -VsInstallPath $vsInstallPath -DevCmdArguments "-arch=x86 -host_arch=amd64" -SkipAutomaticLocation

# 编译32位Shell拓展
Set-Location "$buildDir\CPP\7zip\UI\Explorer"
& nmake PLATFORM=x86

# 回到原始目录
Set-Location $currentDir
