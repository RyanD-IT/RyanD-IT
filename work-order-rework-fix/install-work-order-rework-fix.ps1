param(
    [string]$ProjectRoot = 'C:\Project\prod-vision'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-ProjectFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file was not found: $Path"
    }

    return [System.IO.File]::ReadAllText($Path)
        .Replace("`r`n", "`n")
        .Replace("`r", "`n")
}

function Write-ProjectFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        $Utf8NoBom
    )
}

function Replace-Once {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$OldValue,
        [Parameter(Mandatory)][string]$NewValue,
        [Parameter(Mandatory)][string]$Description
    )

    $First = $Text.IndexOf(
        $OldValue,
        [System.StringComparison]::Ordinal
    )

    if ($First -lt 0) {
        throw "Could not apply $Description. Expected code was not found."
    }

    $Second = $Text.IndexOf(
        $OldValue,
        $First + $OldValue.Length,
        [System.StringComparison]::Ordinal
    )

    if ($Second -ge 0) {
        throw "Could not safely apply $Description because the expected code occurs more than once."
    }

    return (
        $Text.Substring(0, $First)
        + $NewValue
        + $Text.Substring($First + $OldValue.Length)
    )
}

function Replace-RegexOnce {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Replacement,
        [Parameter(Mandatory)][string]$Description
    )

    $Matches = [regex]::Matches(
        $Text,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    if ($Matches.Count -ne 1) {
        throw "Could not safely apply $Description. Expected exactly one match but found $($Matches.Count)."
    }

    return [regex]::Replace(
        $Text,
        $Pattern,
        $Replacement,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
}

$WorkOrderControllerPath = Join-Path $ProjectRoot 'app\Http\Controllers\WorkOrderController.php'
$InspectionControllerPath = Join-Path $ProjectRoot 'app\Http\Controllers\InspectionController.php'
$ProductionControllerPath = Join-Path $ProjectRoot 'app\Http\Controllers\ProductionProcessController.php'
$CreateBladePath = Join-Path $ProjectRoot 'resources\views\control panel\create.blade.php'

$RequiredFiles = @(
    $WorkOrderControllerPath,
    $InspectionControllerPath,
    $ProductionControllerPath,
    $CreateBladePath
)

foreach ($RequiredFile in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath $RequiredFile)) {
        throw "Required file was not found: $RequiredFile"
    }
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDirectory = Join-Path $ProjectRoot "storage\app\work-order-rework-backup-$Timestamp"

New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null

foreach ($SourcePath in $RequiredFiles) {
    Copy-Item \
        -LiteralPath $SourcePath \
        -Destination (Join-Path $BackupDirectory (Split-Path -Leaf $SourcePath)) \
        -Force
}

Write-Host ''
Write-Host 'Backup created:'
Write-Host $BackupDirectory
Write-Host ''

# ============================================================
# 1. InspectionController.php
#    Persist Work Order status as Rework while rework quantity exists.
# ============================================================

$Inspection = Read-ProjectFile -Path $InspectionControllerPath

if (-not $Inspection.Contains('syncLinkedWorkOrderReworkStatus')) {
    $Inspection = Replace-Once \
        -Text $Inspection \
        -OldValue @'
            $saved = collect();
            $affectedOrderIds = collect();
'@ \
        -NewValue @'
            $saved = collect();
            $affectedOrderIds = collect();
            $affectedWorkOrderItems = collect();
'@ \
        -Description 'Inspection affected Work Order collection'

    $Inspection = Replace-Once \
        -Text $Inspection \
        -OldValue @'
                $affectedOrderIds->push((int) $item->purchase_order_id);

                $saved->push([
'@ \
        -NewValue @'
                $affectedOrderIds->push((int) $item->purchase_order_id);
                $affectedWorkOrderItems->push((int) $item->id);

                $saved->push([
'@ \
        -Description 'Inspection Work Order rework synchronization queue'

    $Inspection = Replace-Once \
        -Text $Inspection \
        -OldValue @'
            $affectedOrderIds
                ->unique()
                ->each(fn (int $orderId) => $this->syncOrderQualityStatus($orderId));

            return $saved;
'@ \
        -NewValue @'
            $affectedOrderIds
                ->unique()
                ->each(fn (int $orderId) => $this->syncOrderQualityStatus($orderId));

            $affectedWorkOrderItems
                ->unique()
                ->each(
                    fn (int $itemId) =>
                        $this->syncLinkedWorkOrderReworkStatus($itemId)
                );

            return $saved;
'@ \
        -Description 'Inspection Work Order rework synchronization call'

    $ReworkMethod = @'
    private function syncLinkedWorkOrderReworkStatus(
        int $purchaseOrderItemId
    ): void {
        if (
            ! Schema::hasTable('work_order')
            || ! Schema::hasTable('ppc_purchase_order_items')
            || ! Schema::hasTable('ppc_inspection_results')
            || ! Schema::hasColumn(
                'ppc_inspection_results',
                'rework_qty'
            )
        ) {
            return;
        }

        $sourceItem = DB::table('ppc_purchase_order_items')
            ->where('id', $purchaseOrderItemId)
            ->first();

        if (! $sourceItem) {
            return;
        }

        $workOrderId = trim((string) (
            $sourceItem->production_work_order_id
            ?? ''
        ));

        $workOrderNumber = trim((string) (
            $sourceItem->production_work_order_num
            ?? ''
        ));

        if ($workOrderId === '' && $workOrderNumber === '') {
            return;
        }

        $linkedItems = DB::table('ppc_purchase_order_items')
            ->where(function ($query) use (
                $workOrderId,
                $workOrderNumber
            ) {
                if (
                    $workOrderId !== ''
                    && Schema::hasColumn(
                        'ppc_purchase_order_items',
                        'production_work_order_id'
                    )
                ) {
                    $query->where(
                        'production_work_order_id',
                        $workOrderId
                    );
                }

                if (
                    $workOrderNumber !== ''
                    && Schema::hasColumn(
                        'ppc_purchase_order_items',
                        'production_work_order_num'
                    )
                ) {
                    $method = $workOrderId !== ''
                        && Schema::hasColumn(
                            'ppc_purchase_order_items',
                            'production_work_order_id'
                        )
                            ? 'orWhere'
                            : 'where';

                    $query->{$method}(
                        'production_work_order_num',
                        $workOrderNumber
                    );
                }
            })
            ->pluck('id');

        if ($linkedItems->isEmpty()) {
            return;
        }

        $reworkQuantity = (int) DB::table(
            'ppc_inspection_results'
        )
            ->whereIn(
                'purchase_order_item_id',
                $linkedItems
            )
            ->sum('rework_qty');

        $workOrderQuery = DB::table('work_order')
            ->where(function ($query) use (
                $workOrderId,
                $workOrderNumber
            ) {
                if ($workOrderId !== '') {
                    $query->where(
                        'work_order_id',
                        $workOrderId
                    );
                }

                if ($workOrderNumber !== '') {
                    $method = $workOrderId !== ''
                        ? 'orWhere'
                        : 'where';

                    $query->{$method}(
                        'work_order_num',
                        $workOrderNumber
                    );
                }
            });

        $workOrder = $workOrderQuery->first();

        if (! $workOrder) {
            return;
        }

        $currentStatus = trim((string) (
            $workOrder->status
            ?? 'Pending'
        ));

        $nextStatus = $reworkQuantity > 0
            ? 'Rework'
            : (
                strtolower($currentStatus) === 'rework'
                    ? 'Completed'
                    : $currentStatus
            );

        if ($nextStatus === $currentStatus) {
            return;
        }

        $update = [
            'status' => $nextStatus,
        ];

        if (Schema::hasColumn('work_order', 'updated_at')) {
            $update['updated_at'] = now();
        }

        DB::table('work_order')
            ->where('work_order_id', $workOrder->work_order_id)
            ->update($update);
    }

'@

    $Inspection = Replace-Once \
        -Text $Inspection \
        -OldValue @'
    private function syncOrderQualityStatus(int $purchaseOrderId): void
'@ \
        -NewValue ($ReworkMethod + @'
    private function syncOrderQualityStatus(int $purchaseOrderId): void
'@) \
        -Description 'Inspection linked Work Order rework method'
}

Write-ProjectFile -Path $InspectionControllerPath -Content $Inspection

# ============================================================
# 2. ProductionProcessController.php
#    Production Output must not overwrite an open Rework status.
# ============================================================

$Production = Read-ProjectFile -Path $ProductionControllerPath

if (-not $Production.Contains('linkedWorkOrderReworkQuantity')) {
    $Production = Replace-Once \
        -Text $Production \
        -OldValue @'
        $update = [
            /*
                The existing progress field is used as the Actual Qty fallback
                by the Work Order page.
            */
            'progress' => $actualCompleted,
            'status' => $completed
                ? 'Completed'
                : 'Pending',
        ];
'@ \
        -NewValue @'
        $reworkQuantity = $this
            ->linkedWorkOrderReworkQuantity($workOrder);

        $hasOpenRework = $reworkQuantity > 0;

        $update = [
            /*
                The existing progress field is used as the Actual Qty fallback
                by the Work Order page.
            */
            'progress' => $actualCompleted,
            'status' => $hasOpenRework
                ? 'Rework'
                : (
                    $completed
                        ? 'Completed'
                        : 'Pending'
                ),
        ];
'@ \
        -Description 'Production Output preservation of Rework status'

    $Production = Replace-Once \
        -Text $Production \
        -OldValue @'
        return [
            'actual_completed' => $actualCompleted,
            'progress_percent' => $progressPercent,
            'completed' => $completed,
        ];
    }

    private function wrapColumn(string $column): string
'@ \
        -NewValue @'
        return [
            'actual_completed' => $actualCompleted,
            'progress_percent' => $progressPercent,
            'completed' => $completed && ! $hasOpenRework,
            'rework_quantity' => $reworkQuantity,
        ];
    }

    private function linkedWorkOrderReworkQuantity(
        object $workOrder
    ): int {
        if (
            ! Schema::hasTable('ppc_purchase_order_items')
            || ! Schema::hasTable('ppc_inspection_results')
            || ! Schema::hasColumn(
                'ppc_inspection_results',
                'rework_qty'
            )
        ) {
            return 0;
        }

        $workOrderId = trim((string) (
            $workOrder->work_order_id
            ?? ''
        ));

        $workOrderNumber = trim((string) (
            $workOrder->work_order_num
            ?? ''
        ));

        $linkedItems = DB::table('ppc_purchase_order_items')
            ->where(function ($query) use (
                $workOrderId,
                $workOrderNumber
            ) {
                if (
                    $workOrderId !== ''
                    && Schema::hasColumn(
                        'ppc_purchase_order_items',
                        'production_work_order_id'
                    )
                ) {
                    $query->where(
                        'production_work_order_id',
                        $workOrderId
                    );
                }

                if (
                    $workOrderNumber !== ''
                    && Schema::hasColumn(
                        'ppc_purchase_order_items',
                        'production_work_order_num'
                    )
                ) {
                    $method = $workOrderId !== ''
                        && Schema::hasColumn(
                            'ppc_purchase_order_items',
                            'production_work_order_id'
                        )
                            ? 'orWhere'
                            : 'where';

                    $query->{$method}(
                        'production_work_order_num',
                        $workOrderNumber
                    );
                }
            })
            ->pluck('id');

        if ($linkedItems->isEmpty()) {
            return 0;
        }

        return (int) DB::table('ppc_inspection_results')
            ->whereIn(
                'purchase_order_item_id',
                $linkedItems
            )
            ->sum('rework_qty');
    }

    private function wrapColumn(string $column): string
'@ \
        -Description 'Production Output linked Rework quantity helper'
}

Write-ProjectFile -Path $ProductionControllerPath -Content $Production

# ============================================================
# 3. WorkOrderController.php
#    Return Rework quantity with the Work Order metrics and preserve
#    Inspection state when editing a Rework Work Order.
# ============================================================

$WorkOrder = Read-ProjectFile -Path $WorkOrderControllerPath

$WorkOrder = $WorkOrder.Replace(
    "'status' => ['nullable', 'string', 'in:Pending,Completed'],",
    "'status' => ['nullable', 'string', 'in:Pending,Completed,Rework'],"
)

if (-not $WorkOrder.Contains('inspectionReworkMap')) {
    $WorkOrder = Replace-Once \
        -Text $WorkOrder \
        -OldValue @'
        return $workOrders->mapWithKeys(function ($order) use (
            $productionRows,
            $processRows,
            $ppcAliasesById,
            $ppcAliasesByNumber,
            $normalizeText,
            $normalizeNumber,
            $baseWorkOrderKey,
            $expandAliases
        ) {
'@ \
        -NewValue @'
        $inspectionReworkMap = $this
            ->inspectionReworkMap($workOrders);

        return $workOrders->mapWithKeys(function ($order) use (
            $productionRows,
            $processRows,
            $ppcAliasesById,
            $ppcAliasesByNumber,
            $inspectionReworkMap,
            $normalizeText,
            $normalizeNumber,
            $baseWorkOrderKey,
            $expandAliases
        ) {
'@ \
        -Description 'Work Order Inspection Rework metrics map initialization'

    $WorkOrder = Replace-Once \
        -Text $WorkOrder \
        -OldValue @'
            $workOrderItemKey = $normalizeText(
                $order->item_name
                ?? ''
            );

            $outputRows = $productionRows
'@ \
        -NewValue @'
            $workOrderItemKey = $normalizeText(
                $order->item_name
                ?? ''
            );

            $reworkQuantity = (int) $inspectionReworkMap
                ->get($workOrderExact, 0);

            $outputRows = $productionRows
'@ \
        -Description 'Work Order current Rework quantity lookup'

    $WorkOrder = Replace-Once \
        -Text $WorkOrder \
        -OldValue @'
                        'has_production_output' =>
                            $outputRows->isNotEmpty(),
                        'is_completed' => false,
'@ \
        -NewValue @'
                        'has_production_output' =>
                            $outputRows->isNotEmpty(),
                        'rework_quantity' => $reworkQuantity,
                        'has_rework' => $reworkQuantity > 0,
                        'is_completed' => false,
'@ \
        -Description 'Work Order empty-process Rework metrics'

    $WorkOrder = Replace-Once \
        -Text $WorkOrder \
        -OldValue @'
                    'has_production_output' =>
                        $outputRows->isNotEmpty(),
                    'is_completed' =>
                        $processOutputs->isNotEmpty()
                        && $processOutputs->every(
                            fn ($value) =>
                                (float) $value >= $target
                        ),
'@ \
        -NewValue @'
                    'has_production_output' =>
                        $outputRows->isNotEmpty(),
                    'rework_quantity' => $reworkQuantity,
                    'has_rework' => $reworkQuantity > 0,
                    'is_completed' =>
                        $reworkQuantity <= 0
                        && $processOutputs->isNotEmpty()
                        && $processOutputs->every(
                            fn ($value) =>
                                (float) $value >= $target
                        ),
'@ \
        -Description 'Work Order completion blocked by Rework'

    $InspectionMapMethod = @'
    private function inspectionReworkMap($workOrders)
    {
        if (
            $workOrders->isEmpty()
            || ! Schema::hasTable('ppc_purchase_order_items')
            || ! Schema::hasTable('ppc_inspection_results')
            || ! Schema::hasColumn(
                'ppc_inspection_results',
                'rework_qty'
            )
        ) {
            return collect();
        }

        $workOrderNumbersById = $workOrders
            ->mapWithKeys(function ($order) {
                $id = trim((string) (
                    $order->work_order_id
                    ?? ''
                ));

                if ($id === '') {
                    return [];
                }

                return [
                    $id => $this->workOrderExactKey(
                        (string) (
                            $order->work_order_num
                            ?? ''
                        )
                    ),
                ];
            });

        $select = [
            'inspection.rework_qty',
        ];

        $select[] = Schema::hasColumn(
            'ppc_purchase_order_items',
            'production_work_order_id'
        )
            ? 'item.production_work_order_id'
            : DB::raw("'' AS production_work_order_id");

        $select[] = Schema::hasColumn(
            'ppc_purchase_order_items',
            'production_work_order_num'
        )
            ? 'item.production_work_order_num'
            : DB::raw("'' AS production_work_order_num");

        $rows = DB::table(
            'ppc_purchase_order_items as item'
        )
            ->join(
                'ppc_inspection_results as inspection',
                'inspection.purchase_order_item_id',
                '=',
                'item.id'
            )
            ->select($select)
            ->get();

        $map = collect();

        foreach ($rows as $row) {
            $quantity = (int) (
                $row->rework_qty
                ?? 0
            );

            if ($quantity <= 0) {
                continue;
            }

            $workOrderNumber = $this->workOrderExactKey(
                (string) (
                    $row->production_work_order_num
                    ?? ''
                )
            );

            if ($workOrderNumber === '') {
                $workOrderId = trim((string) (
                    $row->production_work_order_id
                    ?? ''
                ));

                $workOrderNumber = (string) $workOrderNumbersById
                    ->get($workOrderId, '');
            }

            if ($workOrderNumber === '') {
                continue;
            }

            $map->put(
                $workOrderNumber,
                (int) $map->get($workOrderNumber, 0)
                    + $quantity
            );
        }

        return $map;
    }

'@

    $WorkOrder = Replace-Once \
        -Text $WorkOrder \
        -OldValue @'
    private function productStats()
'@ \
        -NewValue ($InspectionMapMethod + @'
    private function productStats()
'@) \
        -Description 'Work Order Inspection Rework map helper'
}

if (-not $WorkOrder.Contains("if (strtolower(trim(`$status)) === 'rework')")) {
    $WorkOrder = Replace-Once \
        -Text $WorkOrder \
        -OldValue @'
        if (! Schema::hasTable('ppc_purchase_order_items')) {
            return;
        }

        $query = DB::table('ppc_purchase_order_items');
'@ \
        -NewValue @'
        if (! Schema::hasTable('ppc_purchase_order_items')) {
            return;
        }

        /*
            Rework is owned by Inspection. Editing the Work Order must not
            reset its PPC Inspection status back to Pending or Ready.
        */
        if (strtolower(trim($status)) === 'rework') {
            return;
        }

        $query = DB::table('ppc_purchase_order_items');
'@ \
        -Description 'Work Order PPC state preservation during Rework'
}

Write-ProjectFile -Path $WorkOrderControllerPath -Content $WorkOrder

# ============================================================
# 4. create.blade.php
#    Display Rework — quantity and prevent automatic Completed status.
# ============================================================

$Blade = Read-ProjectFile -Path $CreateBladePath

if (-not $Blade.Contains('$inspectionReworkMap = collect();')) {
    $BladeReworkMap = @'

    /*
        Inspection Rework quantity by exact Production Work Order.
        The Work Order may remain at 100% Production Progress, but it is not
        Completed while Inspection still has an open Rework quantity.
    */
    $inspectionReworkMap = collect();

    try {
        if (
            $workOrders->isNotEmpty()
            && Schema::hasTable('ppc_purchase_order_items')
            && Schema::hasTable('ppc_inspection_results')
            && Schema::hasColumn(
                'ppc_inspection_results',
                'rework_qty'
            )
        ) {
            $workOrderNumbersById = $workOrders
                ->mapWithKeys(function ($order) use (
                    $exactWorkOrderKeyForList
                ) {
                    $id = trim((string) (
                        $order->work_order_id
                        ?? ''
                    ));

                    if ($id === '') {
                        return [];
                    }

                    return [
                        $id => $exactWorkOrderKeyForList(
                            $order->work_order_num
                            ?? ''
                        ),
                    ];
                });

            $select = [
                'inspection.rework_qty',
            ];

            $select[] = Schema::hasColumn(
                'ppc_purchase_order_items',
                'production_work_order_id'
            )
                ? 'item.production_work_order_id'
                : DB::raw(
                    "'' AS production_work_order_id"
                );

            $select[] = Schema::hasColumn(
                'ppc_purchase_order_items',
                'production_work_order_num'
            )
                ? 'item.production_work_order_num'
                : DB::raw(
                    "'' AS production_work_order_num"
                );

            $inspectionRows = DB::table(
                'ppc_purchase_order_items as item'
            )
                ->join(
                    'ppc_inspection_results as inspection',
                    'inspection.purchase_order_item_id',
                    '=',
                    'item.id'
                )
                ->select($select)
                ->get();

            foreach ($inspectionRows as $inspectionRow) {
                $reworkQuantity = (int) (
                    $inspectionRow->rework_qty
                    ?? 0
                );

                if ($reworkQuantity <= 0) {
                    continue;
                }

                $workOrderNumber = $exactWorkOrderKeyForList(
                    $inspectionRow->production_work_order_num
                    ?? ''
                );

                if ($workOrderNumber === '') {
                    $workOrderId = trim((string) (
                        $inspectionRow->production_work_order_id
                        ?? ''
                    ));

                    $workOrderNumber = (string) $workOrderNumbersById
                        ->get($workOrderId, '');
                }

                if ($workOrderNumber === '') {
                    continue;
                }

                $inspectionReworkMap->put(
                    $workOrderNumber,
                    (int) $inspectionReworkMap->get(
                        $workOrderNumber,
                        0
                    ) + $reworkQuantity
                );
            }
        }
    } catch (\Throwable $exception) {
        $inspectionReworkMap = collect();
    }
'@

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
    $numberValue = function ($value): float {
'@ \
        -NewValue ($BladeReworkMap + @'

    $numberValue = function ($value): float {
'@) \
        -Description 'Work Order Blade Inspection Rework map'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
                            ->filter(function ($order) use (
                                $actualMap,
                                $exactWorkOrderKeyForList
                            ) {
'@ \
        -NewValue @'
                            ->filter(function ($order) use (
                                $actualMap,
                                $inspectionReworkMap,
                                $exactWorkOrderKeyForList
                            ) {
'@ \
        -Description 'Completed count Rework map dependency'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
                                $automaticCompleted = (bool) (
                                    $actualMap
                                        ->get($workOrderKey)
                                        ?->is_completed
                                    ?? false
                                );

                                return $automaticCompleted
'@ \
        -NewValue @'
                                $reworkQuantity = (int) $inspectionReworkMap
                                    ->get($workOrderKey, 0);

                                if ($reworkQuantity > 0) {
                                    return false;
                                }

                                $automaticCompleted = (bool) (
                                    $actualMap
                                        ->get($workOrderKey)
                                        ?->is_completed
                                    ?? false
                                );

                                return $automaticCompleted
'@ \
        -Description 'Completed count exclusion for Rework'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
                                                $automaticCompleted = (bool) (
                                                    $actual->is_completed
                                                    ?? false
                                                );

                                                $statusKey = $automaticCompleted
                                                    ? 'completed'
                                                    : Str::lower((string) $order->status);

                                                $displayStatus = $statusKey === 'completed'
                                                    ? 'Completed'
                                                    : 'Pending';

                                                $statusClass = $statusKey === 'completed'
                                                    ? 'status-completed'
                                                    : 'status-pending';
'@ \
        -NewValue @'
                                                $automaticCompleted = (bool) (
                                                    $actual->is_completed
                                                    ?? false
                                                );

                                                $reworkQuantity = (int) $inspectionReworkMap
                                                    ->get($woKey, 0);

                                                $storedStatus = Str::lower(
                                                    (string) (
                                                        $order->status
                                                        ?? ''
                                                    )
                                                );

                                                $hasRework = $reworkQuantity > 0
                                                    || $storedStatus === 'rework';

                                                $statusKey = $hasRework
                                                    ? 'rework'
                                                    : (
                                                        $automaticCompleted
                                                            ? 'completed'
                                                            : $storedStatus
                                                    );

                                                $displayStatus = match ($statusKey) {
                                                    'rework' => $reworkQuantity > 0
                                                        ? 'Rework — '
                                                            . number_format(
                                                                $reworkQuantity
                                                            )
                                                        : 'Rework',
                                                    'completed' => 'Completed',
                                                    default => 'Pending',
                                                };

                                                $statusClass = match ($statusKey) {
                                                    'rework' => 'status-rework',
                                                    'completed' => 'status-completed',
                                                    default => 'status-pending',
                                                };
'@ \
        -Description 'Work Order row Rework status and quantity'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
        .status-completed {
            color: #166534;
            background: #ecfdf3;
            border: 1px solid #bbf7d0;
        }

        .status-incomplete {
'@ \
        -NewValue @'
        .status-completed {
            color: #166534;
            background: #ecfdf3;
            border: 1px solid #bbf7d0;
        }

        .status-rework {
            min-width: 122px;
            color: #9a3412;
            background: #fff7ed;
            border: 1px solid #fdba74;
            white-space: nowrap;
        }

        .status-incomplete {
'@ \
        -Description 'Work Order Rework status styling'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
        function normalizeWorkOrderStatus(value) {
            return String(value || '').trim().toLowerCase() === 'completed'
                ? 'Completed'
                : 'Pending';
        }
'@ \
        -NewValue @'
        function normalizeWorkOrderStatus(value) {
            const normalized = String(value || '')
                .trim()
                .toLowerCase();

            if (normalized.startsWith('rework')) {
                return 'Rework';
            }

            return normalized === 'completed'
                ? 'Completed'
                : 'Pending';
        }
'@ \
        -Description 'Work Order JavaScript Rework status normalization'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
            if (pill) {
                pill.textContent = normalizedStatus;
                pill.classList.remove('status-pending', 'status-completed');
                pill.classList.add(normalizedStatus === 'Completed' ? 'status-completed' : 'status-pending');
            }
'@ \
        -NewValue @'
            if (pill) {
                pill.textContent = normalizedStatus;
                pill.classList.remove(
                    'status-pending',
                    'status-completed',
                    'status-rework'
                );

                pill.classList.add(
                    normalizedStatus === 'Completed'
                        ? 'status-completed'
                        : (
                            normalizedStatus === 'Rework'
                                ? 'status-rework'
                                : 'status-pending'
                        )
                );
            }
'@ \
        -Description 'Work Order JavaScript Rework pill styling'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
            const normalizedStatus = normalizeWorkOrderStatus(status);
            const isCompleted = normalizedStatus === 'Completed';

            workOrderStatus.value = normalizedStatus;
            markCompletedButton.textContent = 'Mark as Completed';
            markCompletedButton.classList.toggle('is-completed', isCompleted);
            markCompletedButton.setAttribute('aria-pressed', isCompleted ? 'true' : 'false');
            markCompletedButton.title = isCompleted
                ? 'Current status is Completed. Press to turn this work order back to Pending.'
                : 'Current status is Pending. Press to mark this work order as Completed.';
'@ \
        -NewValue @'
            const normalizedStatus = normalizeWorkOrderStatus(status);
            const isCompleted = normalizedStatus === 'Completed';
            const isRework = normalizedStatus === 'Rework';

            workOrderStatus.value = normalizedStatus;
            markCompletedButton.disabled = isRework;
            markCompletedButton.textContent = isRework
                ? 'Rework in Progress'
                : 'Mark as Completed';
            markCompletedButton.classList.toggle('is-completed', isCompleted);
            markCompletedButton.setAttribute('aria-pressed', isCompleted ? 'true' : 'false');
            markCompletedButton.title = isRework
                ? 'Inspection has open Rework quantity. Clear the Rework result before marking this Work Order Completed.'
                : (
                    isCompleted
                        ? 'Current status is Completed. Press to turn this work order back to Pending.'
                        : 'Current status is Pending. Press to mark this work order as Completed.'
                );
'@ \
        -Description 'Work Order edit modal Rework protection'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
            if (markCompletedButton) {
                markCompletedButton.classList.remove('is-visible', 'is-completed');
                markCompletedButton.setAttribute('aria-pressed', 'false');
                markCompletedButton.textContent = 'Mark as Completed';
            }
'@ \
        -NewValue @'
            if (markCompletedButton) {
                markCompletedButton.disabled = false;
                markCompletedButton.classList.remove('is-visible', 'is-completed');
                markCompletedButton.setAttribute('aria-pressed', 'false');
                markCompletedButton.textContent = 'Mark as Completed';
            }
'@ \
        -Description 'Work Order add modal Rework button reset'

    $Blade = Replace-Once \
        -Text $Blade \
        -OldValue @'
        markCompletedButton?.addEventListener('click', function () {
            if (!workOrderStatus || this.classList.contains('is-visible') === false) {
                return;
            }
'@ \
        -NewValue @'
        markCompletedButton?.addEventListener('click', function () {
            if (
                ! workOrderStatus
                || this.disabled
                || this.classList.contains('is-visible') === false
            ) {
                return;
            }
'@ \
        -Description 'Work Order Rework manual completion block'
}

Write-ProjectFile -Path $CreateBladePath -Content $Blade

# ============================================================
# Validate and clear caches.
# ============================================================

Write-Host ''
Write-Host 'Checking PHP syntax...'

foreach ($PhpFile in @(
    $WorkOrderControllerPath,
    $InspectionControllerPath,
    $ProductionControllerPath
)) {
    & php -l $PhpFile

    if ($LASTEXITCODE -ne 0) {
        throw "PHP syntax validation failed: $PhpFile"
    }
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
Write-Host 'WORK ORDER REWORK STATUS FIX COMPLETED'
Write-Host '======================================================'
Write-Host ''
Write-Host 'Behavior:'
Write-Host '- Inspection Rework Qty greater than zero changes the linked Work Order to Rework.'
Write-Host '- The Work Order list displays Rework and its quantity.'
Write-Host '- Automatic Production completion cannot override open Rework.'
Write-Host '- When Inspection Rework Qty becomes zero, the Work Order returns to Completed.'
Write-Host '- Existing production, inspection, and PPC records are preserved.'
Write-Host ''
Write-Host 'Backup:'
Write-Host $BackupDirectory
Write-Host ''
Write-Host 'Restart Laravel and refresh the Work Order page with Ctrl + F5.'
