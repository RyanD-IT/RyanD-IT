param(
    [string]$ProjectRoot = 'C:\Project\prod-vision'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file was not found: $Path"
    }

    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        $utf8NoBom
    )
}

function Replace-Once {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$OldValue,
        [Parameter(Mandatory)][string]$NewValue,
        [Parameter(Mandatory)][string]$Description
    )

    $first = $Text.IndexOf(
        $OldValue,
        [System.StringComparison]::Ordinal
    )

    if ($first -lt 0) {
        throw "Could not apply $Description. Expected source text was not found."
    }

    $second = $Text.IndexOf(
        $OldValue,
        $first + $OldValue.Length,
        [System.StringComparison]::Ordinal
    )

    if ($second -ge 0) {
        throw "Could not safely apply $Description because the source text occurs more than once."
    }

    return (
        $Text.Substring(0, $first)
        + $NewValue
        + $Text.Substring($first + $OldValue.Length)
    )
}

function Normalize-NewLines {
    param([Parameter(Mandatory)][string]$Text)

    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

$productionControllerPath = Join-Path \
    $ProjectRoot \
    'app\Http\Controllers\ProductionProcessController.php'

$machineControllerPath = Join-Path \
    $ProjectRoot \
    'app\Http\Controllers\MachineController.php'

$machine30BladePath = Join-Path \
    $ProjectRoot \
    'resources\views\discover\die-mold\die-mold-machine30.blade.php'

$discoverIndexPath = Join-Path \
    $ProjectRoot \
    'resources\views\discover\index.blade.php'

$spotWeldImagePath = Join-Path \
    $ProjectRoot \
    'public\photos\Spot Weld.png'

$requiredFiles = @(
    $productionControllerPath,
    $machineControllerPath,
    $machine30BladePath,
    $discoverIndexPath,
    $spotWeldImagePath
)

foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
        throw "Required Machine 30 integration file was not found: $requiredFile"
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDirectory = Join-Path \
    $ProjectRoot \
    "storage\app\machine30-system-backup-$timestamp"

New-Item \
    -ItemType Directory \
    -Path $backupDirectory \
    -Force | Out-Null

foreach ($sourcePath in @(
    $productionControllerPath,
    $machineControllerPath,
    $machine30BladePath,
    $discoverIndexPath
)) {
    Copy-Item \
        -LiteralPath $sourcePath \
        -Destination (Join-Path $backupDirectory (Split-Path -Leaf $sourcePath)) \
        -Force
}

Write-Host ''
Write-Host 'Backup created:'
Write-Host $backupDirectory
Write-Host ''

# ============================================================
# 1. ProductionProcessController
#    Fixes the exact error:
#    "The selected Die Mold machine was not found or is not allowed."
# ============================================================

$productionController = Normalize-NewLines (
    Read-TextFile -Path $productionControllerPath
)

if (-not $productionController.Contains("'NHM-SW-01'")) {
    $productionController = Replace-Once \
        -Text $productionController \
        -OldValue @"
        'NHM-AVR-007',
        'NHM-GR-04',
    ];
"@ \
        -NewValue @"
        'NHM-AVR-007',
        'NHM-GR-04',
        'NHM-SW-01',
    ];
"@ \
        -Description 'the Spot Weld Die Mold allowlist entry'
}

# Keep the stable control number as the production_output Machine_Num value.
# This makes Discover, Production Output, Report, and Machine 30 use the same
# identifier even when the SQL machine table also has a numeric M_ID.
$oldResolverStart = @"
    private function resolveDieMoldMachine(
        string `$value
    ): ?array {
"@

$nextMethodMarker = @"
    private function workOrderNumberVariants(string `$workOrderNumber): array
"@

$resolverStart = $productionController.IndexOf(
    $oldResolverStart,
    [System.StringComparison]::Ordinal
)

$resolverEnd = $productionController.IndexOf(
    $nextMethodMarker,
    [System.StringComparison]::Ordinal
)

if ($resolverStart -lt 0 -or $resolverEnd -le $resolverStart) {
    throw 'Could not locate resolveDieMoldMachine() in ProductionProcessController.php.'
}

$newResolver = @'
    private function resolveDieMoldMachine(
        string $value
    ): ?array {
        $value = trim($value);

        if ($value === '') {
            return null;
        }

        /*
            Stable control numbers are the canonical Die Mold identifiers.
            Resolve them before SQL M_ID lookup so Production Output saves the
            same NHM control used by Discover, Machine pages, and Reports.
        */
        $allowedControl = collect(
            self::DIE_MOLD_MACHINE_CONTROLS
        )->first(
            fn ($control) =>
                strcasecmp(
                    $control,
                    $value
                ) === 0
        );

        if ($allowedControl) {
            $label = $allowedControl;

            if (
                Schema::hasTable('machine')
                && Schema::hasColumn('machine', 'Machine_Num')
            ) {
                $machine = DB::table('machine')
                    ->select([
                        Schema::hasColumn('machine', 'M_ID')
                            ? 'M_ID'
                            : DB::raw('NULL AS M_ID'),
                        'Machine_Num',
                    ])
                    ->whereRaw(
                        'UPPER(TRIM(Machine_Num)) = ?',
                        [mb_strtoupper($allowedControl)]
                    )
                    ->first();

                $sqlLabel = trim((string) (
                    $machine->Machine_Num
                    ?? ''
                ));

                if ($sqlLabel !== '') {
                    $label = $sqlLabel;
                }
            }

            return [
                'output_value' => $allowedControl,
                'label' => $label,
            ];
        }

        /*
            Numeric SQL M_ID values remain supported for existing Die Mold
            options and historical integrations.
        */
        if (
            ctype_digit($value)
            && Schema::hasTable('machine')
            && Schema::hasColumn('machine', 'M_ID')
            && Schema::hasColumn('machine', 'Machine_Num')
        ) {
            $machine = DB::table('machine')
                ->select([
                    'M_ID',
                    'Machine_Num',
                ])
                ->where('M_ID', (int) $value)
                ->first();

            if ($machine) {
                $machineName = trim((string) (
                    $machine->Machine_Num
                    ?? ''
                ));

                return [
                    'output_value' => (string) $machine->M_ID,
                    'label' => $machineName !== ''
                        ? $machineName
                        : $value,
                ];
            }
        }

        /*
            Reject arbitrary text that is neither a configured NHM Die Mold
            control number nor a valid numeric SQL machine ID.
        */
        return null;
    }

'@

$productionController = (
    $productionController.Substring(0, $resolverStart)
    + $newResolver
    + $productionController.Substring($resolverEnd)
)

Write-TextFile \
    -Path $productionControllerPath \
    -Content $productionController

# ============================================================
# 2. MachineController
#    Registers Machine 30 consistently for page/date/output lookup.
# ============================================================

$machineController = Normalize-NewLines (
    Read-TextFile -Path $machineControllerPath
)

$machine30Pattern = '(?s)            30 => \[.*?            \],\n        \];'

$machine30Replacement = @'
            30 => [
                'number' => 30,
                'name' => 'SPOT WELD',
                'control' => 'NHM-SW-01',
                'model' => 'N/A',
                'brand' => 'CHUO',
                'serial' => 'N/A',
                'function' => 'SPOT WELDING',
                'aliases' => [
                    'SPOT WELD',
                    'SPOT WELDING',
                    'CHUO',
                    'CHOU',
                    'NHM-SW-01',
                ],
            ],
        ];
'@

$machine30Match = [regex]::Match(
    $machineController,
    $machine30Pattern
)

if (-not $machine30Match.Success) {
    throw 'Could not locate the Machine 30 definition in MachineController.php.'
}

$machineController = [regex]::Replace(
    $machineController,
    $machine30Pattern,
    $machine30Replacement,
    1
)

$machineController = $machineController.Replace(
    'Display one of the 29 Die Mold machine pages.',
    'Display one of the 30 Die Mold machine pages.'
)

$machineController = $machineController.Replace(
    'Die Mold Machine 1-29',
    'Die Mold Machine 1-30'
)

Write-TextFile \
    -Path $machineControllerPath \
    -Content $machineController

# ============================================================
# 3. Machine 30 Blade
#    Corrects identity, brand, serial, function, and image.
# ============================================================

$machine30Blade = Normalize-NewLines (
    Read-TextFile -Path $machine30BladePath
)

$machine30Blade = $machine30Blade.Replace(
    "`$machineManufacturer = 'CHOU';",
    "`$machineManufacturer = 'CHUO';"
)

$machine30Blade = $machine30Blade.Replace(
    "`$machineFunction = 'SPOT WELD';",
    "`$machineFunction = 'SPOT WELDING';"
)

if (-not $machine30Blade.Contains('$machineSerialNumber')) {
    $machine30Blade = Replace-Once \
        -Text $machine30Blade \
        -OldValue @"
    `$machineModel = 'N/A';
    `$machineManufacturer = 'CHUO';
"@ \
        -NewValue @"
    `$machineModel = 'N/A';
    `$machineManufacturer = 'CHUO';
    `$machineSerialNumber = 'N/A';
"@ \
        -Description 'the Machine 30 serial number variable'
}

$machine30Blade = $machine30Blade.Replace(
    "asset('photos/Surface Grinder- Machine 1.png')",
    "asset('photos/Spot Weld.png')"
)

$machine30Blade = $machine30Blade.Replace(
    @"
                    {{ `$machineModel }}, manufactured by
                    {{ `$machineManufacturer }}, with asset number
                    {{ `$machineAssetNumber }}.
"@,
    @"
                    {{ `$machineModel }}, manufactured by
                    {{ `$machineManufacturer }}, with serial number
                    {{ `$machineSerialNumber }} and asset number
                    {{ `$machineAssetNumber }}.
"@
)

Write-TextFile \
    -Path $machine30BladePath \
    -Content $machine30Blade

# ============================================================
# 4. Verify Discover index already contains Machine 30.
# ============================================================

$discoverIndex = Read-TextFile -Path $discoverIndexPath

if (-not $discoverIndex.Contains('NHM-SW-01')) {
    throw 'Discover index does not contain NHM-SW-01. Add the Machine 30 definition before continuing.'
}

if (-not $discoverIndex.Contains('photos/Spot Weld.png')) {
    throw 'Discover index does not link Machine 30 to photos/Spot Weld.png.'
}

# ============================================================
# 5. Validate and clear Laravel caches.
# ============================================================

Write-Host ''
Write-Host 'Checking PHP syntax...'

& php -l $productionControllerPath
if ($LASTEXITCODE -ne 0) {
    throw 'ProductionProcessController.php failed PHP syntax validation.'
}

& php -l $machineControllerPath
if ($LASTEXITCODE -ne 0) {
    throw 'MachineController.php failed PHP syntax validation.'
}

Push-Location $ProjectRoot

try {
    & php artisan optimize:clear
    if ($LASTEXITCODE -ne 0) {
        throw 'php artisan optimize:clear failed.'
    }

    & php artisan view:clear
    if ($LASTEXITCODE -ne 0) {
        throw 'php artisan view:clear failed.'
    }

    & php artisan cache:clear
    if ($LASTEXITCODE -ne 0) {
        throw 'php artisan cache:clear failed.'
    }
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host '======================================================'
Write-Host 'MACHINE 30 SPOT WELD SYSTEM LINKING COMPLETED'
Write-Host '======================================================'
Write-Host 'Machine Name : SPOT WELD'
Write-Host 'Control No.  : NHM-SW-01'
Write-Host 'Model        : N/A'
Write-Host 'Brand        : CHUO'
Write-Host 'Serial No.   : N/A'
Write-Host 'Department   : DIE MOLD'
Write-Host 'Image        : public\photos\Spot Weld.png'
Write-Host ''
Write-Host 'The Production Output controller now accepts NHM-SW-01.'
Write-Host 'Production rows use NHM-SW-01 as the stable Machine_Num.'
Write-Host 'Machine 30 page aliases support SQL control, name, and M_ID matching.'
Write-Host ''
Write-Host 'Backup location:'
Write-Host $backupDirectory
Write-Host ''
Write-Host 'Restart Laravel, open Discover, and submit Spot Weld output again.'
