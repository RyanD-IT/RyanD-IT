<?php

declare(strict_types=1);

/**
 * Work Order Rework Status integration patch.
 *
 * Run from the project root:
 *
 *     php apply_work_order_rework_fix.php
 *
 * This updates:
 *   - app/Http/Controllers/InspectionController.php
 *   - app/Http/Controllers/ProductionProcessController.php
 *   - app/Http/Controllers/WorkOrderController.php
 *   - resources/views/control panel/create.blade.php
 *
 * It creates timestamped backups before changing anything.
 */

$projectRoot = $argv[1] ?? __DIR__;
$projectRoot = rtrim(str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $projectRoot), DIRECTORY_SEPARATOR);

$paths = [
    'inspection' => $projectRoot . DIRECTORY_SEPARATOR . 'app' . DIRECTORY_SEPARATOR . 'Http' . DIRECTORY_SEPARATOR . 'Controllers' . DIRECTORY_SEPARATOR . 'InspectionController.php',
    'production' => $projectRoot . DIRECTORY_SEPARATOR . 'app' . DIRECTORY_SEPARATOR . 'Http' . DIRECTORY_SEPARATOR . 'Controllers' . DIRECTORY_SEPARATOR . 'ProductionProcessController.php',
    'work_order' => $projectRoot . DIRECTORY_SEPARATOR . 'app' . DIRECTORY_SEPARATOR . 'Http' . DIRECTORY_SEPARATOR . 'Controllers' . DIRECTORY_SEPARATOR . 'WorkOrderController.php',
    'blade' => $projectRoot . DIRECTORY_SEPARATOR . 'resources' . DIRECTORY_SEPARATOR . 'views' . DIRECTORY_SEPARATOR . 'control panel' . DIRECTORY_SEPARATOR . 'create.blade.php',
];

foreach ($paths as $name => $path) {
    if (! is_file($path)) {
        fwrite(STDERR, "Required {$name} file was not found: {$path}\n");
        exit(1);
    }
}

$backupDirectory = $projectRoot
    . DIRECTORY_SEPARATOR . 'storage'
    . DIRECTORY_SEPARATOR . 'app'
    . DIRECTORY_SEPARATOR . 'work-order-rework-backup-'
    . date('Ymd-His');

if (! is_dir($backupDirectory) && ! mkdir($backupDirectory, 0777, true) && ! is_dir($backupDirectory)) {
    fwrite(STDERR, "Could not create backup directory: {$backupDirectory}\n");
    exit(1);
}

foreach ($paths as $path) {
    $destination = $backupDirectory . DIRECTORY_SEPARATOR . basename($path);

    if (! copy($path, $destination)) {
        fwrite(STDERR, "Could not back up {$path}\n");
        exit(1);
    }
}

function readFileStrict(string $path): string
{
    $contents = file_get_contents($path);

    if ($contents === false) {
        throw new RuntimeException("Could not read {$path}");
    }

    return str_replace(["\r\n", "\r"], "\n", $contents);
}

function writeFileStrict(string $path, string $contents): void
{
    if (file_put_contents($path, $contents) === false) {
        throw new RuntimeException("Could not write {$path}");
    }
}

function replaceOnce(
    string $contents,
    string $search,
    string $replacement,
    string $description
): string {
    $first = strpos($contents, $search);

    if ($first === false) {
        throw new RuntimeException("Could not apply {$description}: expected code was not found.");
    }

    if (strpos($contents, $search, $first + strlen($search)) !== false) {
        throw new RuntimeException("Could not safely apply {$description}: expected code occurs more than once.");
    }

    return substr($contents, 0, $first)
        . $replacement
        . substr($contents, $first + strlen($search));
}

function replaceFirst(
    string $contents,
    string $search,
    string $replacement,
    string $description
): string {
    $first = strpos($contents, $search);

    if ($first === false) {
        throw new RuntimeException("Could not apply {$description}: expected code was not found.");
    }

    return substr($contents, 0, $first)
        . $replacement
        . substr($contents, $first + strlen($search));
}

try {
    /* ========================================================
     * InspectionController.php
     * ====================================================== */
    $inspection = readFileStrict($paths['inspection']);

    if (! str_contains($inspection, 'syncLinkedWorkOrderReworkStatus')) {
        $inspection = replaceOnce(
            $inspection,
            <<<'PHP'
            $saved = collect();
            $affectedOrderIds = collect();
PHP,
            <<<'PHP'
            $saved = collect();
            $affectedOrderIds = collect();
            $affectedWorkOrderItems = collect();
PHP,
            'Inspection affected Work Order collection'
        );

        $inspection = replaceOnce(
            $inspection,
            <<<'PHP'
                $affectedOrderIds->push((int) $item->purchase_order_id);

                $saved->push([
PHP,
            <<<'PHP'
                $affectedOrderIds->push((int) $item->purchase_order_id);
                $affectedWorkOrderItems->push((int) $item->id);

                $saved->push([
PHP,
            'Inspection affected Work Order item tracking'
        );

        $inspection = replaceOnce(
            $inspection,
            <<<'PHP'
            $affectedOrderIds
                ->unique()
                ->each(fn (int $orderId) => $this->syncOrderQualityStatus($orderId));

            return $saved;
PHP,
            <<<'PHP'
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
PHP,
            'Inspection linked Work Order synchronization call'
        );

        $reworkMethod = <<<'PHP'
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

        $linkedItemIds = DB::table('ppc_purchase_order_items')
            ->where(function ($query) use (
                $workOrderId,
                $workOrderNumber
            ) {
                $hasIdColumn = Schema::hasColumn(
                    'ppc_purchase_order_items',
                    'production_work_order_id'
                );

                $hasNumberColumn = Schema::hasColumn(
                    'ppc_purchase_order_items',
                    'production_work_order_num'
                );

                if ($hasIdColumn && $workOrderId !== '') {
                    $query->where(
                        'production_work_order_id',
                        $workOrderId
                    );
                }

                if ($hasNumberColumn && $workOrderNumber !== '') {
                    $method = $hasIdColumn && $workOrderId !== ''
                        ? 'orWhere'
                        : 'where';

                    $query->{$method}(
                        'production_work_order_num',
                        $workOrderNumber
                    );
                }
            })
            ->pluck('id');

        if ($linkedItemIds->isEmpty()) {
            return;
        }

        $reworkQuantity = (int) DB::table(
            'ppc_inspection_results'
        )
            ->whereIn(
                'purchase_order_item_id',
                $linkedItemIds
            )
            ->sum('rework_qty');

        $workOrder = DB::table('work_order')
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
            })
            ->first();

        if (! $workOrder) {
            return;
        }

        $currentStatus = strtolower(trim((string) (
            $workOrder->status
            ?? 'pending'
        )));

        if ($reworkQuantity > 0) {
            $nextStatus = 'Rework';
        } elseif ($currentStatus === 'rework') {
            $nextStatus = 'Completed';
        } else {
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

PHP;

        $inspection = replaceOnce(
            $inspection,
            '    private function syncOrderQualityStatus(int $purchaseOrderId): void' . "\n",
            $reworkMethod
                . '    private function syncOrderQualityStatus(int $purchaseOrderId): void'
                . "\n",
            'Inspection linked Work Order Rework method'
        );
    }

    writeFileStrict($paths['inspection'], $inspection);

    /* ========================================================
     * ProductionProcessController.php
     * ====================================================== */
    $production = readFileStrict($paths['production']);

    if (! str_contains($production, 'linkedWorkOrderReworkQuantity')) {
        $production = replaceOnce(
            $production,
            <<<'PHP'
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
PHP,
            <<<'PHP'
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
PHP,
            'Production completion protection for open Rework'
        );

        $production = replaceOnce(
            $production,
            <<<'PHP'
        return [
            'actual_completed' => $actualCompleted,
            'progress_percent' => $progressPercent,
            'completed' => $completed,
        ];
    }

PHP,
            <<<'PHP'
        return [
            'actual_completed' => $actualCompleted,
            'progress_percent' => $progressPercent,
            'completed' => $completed && ! $hasOpenRework,
            'rework_quantity' => $reworkQuantity,
        ];
    }

PHP,
            'Production synchronized metrics Rework state'
        );

        $helper = <<<'PHP'
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

        $linkedItemIds = DB::table('ppc_purchase_order_items')
            ->where(function ($query) use (
                $workOrderId,
                $workOrderNumber
            ) {
                $hasIdColumn = Schema::hasColumn(
                    'ppc_purchase_order_items',
                    'production_work_order_id'
                );

                $hasNumberColumn = Schema::hasColumn(
                    'ppc_purchase_order_items',
                    'production_work_order_num'
                );

                if ($hasIdColumn && $workOrderId !== '') {
                    $query->where(
                        'production_work_order_id',
                        $workOrderId
                    );
                }

                if ($hasNumberColumn && $workOrderNumber !== '') {
                    $method = $hasIdColumn && $workOrderId !== ''
                        ? 'orWhere'
                        : 'where';

                    $query->{$method}(
                        'production_work_order_num',
                        $workOrderNumber
                    );
                }
            })
            ->pluck('id');

        if ($linkedItemIds->isEmpty()) {
            return 0;
        }

        return (int) DB::table('ppc_inspection_results')
            ->whereIn(
                'purchase_order_item_id',
                $linkedItemIds
            )
            ->sum('rework_qty');
    }

PHP;

        $production = replaceOnce(
            $production,
            '    private function wrapColumn(string $column): string' . "\n",
            $helper
                . '    private function wrapColumn(string $column): string'
                . "\n",
            'Production linked Rework quantity helper'
        );
    }

    writeFileStrict($paths['production'], $production);

    /* ========================================================
     * WorkOrderController.php
     * ====================================================== */
    $workOrder = readFileStrict($paths['work_order']);

    $workOrder = str_replace(
        "'status' => ['nullable', 'string', 'in:Pending,Completed'],",
        "'status' => ['nullable', 'string', 'in:Pending,Completed,Rework'],",
        $workOrder
    );

    writeFileStrict($paths['work_order'], $workOrder);

    /* ========================================================
     * create.blade.php
     * ====================================================== */
    $blade = readFileStrict($paths['blade']);

    if (! str_contains($blade, '$inspectionReworkMap = collect();')) {
        $mapBlock = <<<'PHP'

    /*
        Open Inspection Rework quantity by exact Production Work Order.
        A Work Order can have 100% Production Progress and still remain in
        Rework until Inspection changes the Rework quantity back to zero.
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

                    $workOrderNumber = (string)
                        $workOrderNumbersById->get(
                            $workOrderId,
                            ''
                        );
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
PHP;

        $blade = replaceOnce(
            $blade,
            '    $numberValue = function ($value): float {' . "\n",
            $mapBlock
                . "\n\n"
                . '    $numberValue = function ($value): float {'
                . "\n",
            'Work Order page Inspection Rework map'
        );

        $blade = replaceFirst(
            $blade,
            <<<'PHP'
                            ->filter(function ($order) use (
                                $actualMap,
                                $exactWorkOrderKeyForList
                            ) {
PHP,
            <<<'PHP'
                            ->filter(function ($order) use (
                                $actualMap,
                                $inspectionReworkMap,
                                $exactWorkOrderKeyForList
                            ) {
PHP,
            'Completed summary Rework dependency'
        );

        $blade = replaceFirst(
            $blade,
            <<<'PHP'
                                $automaticCompleted = (bool) (
                                    $actualMap
                                        ->get($workOrderKey)
                                        ?->is_completed
                                    ?? false
                                );

                                return $automaticCompleted
PHP,
            <<<'PHP'
                                $reworkQuantity = (int)
                                    $inspectionReworkMap->get(
                                        $workOrderKey,
                                        0
                                    );

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
PHP,
            'Completed summary exclusion for Rework'
        );

        $blade = replaceOnce(
            $blade,
            <<<'PHP'
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
PHP,
            <<<'PHP'
                                                $automaticCompleted = (bool) (
                                                    $actual->is_completed
                                                    ?? false
                                                );

                                                $reworkQuantity = (int)
                                                    $inspectionReworkMap->get(
                                                        $woKey,
                                                        0
                                                    );

                                                $storedStatus = Str::lower(
                                                    trim((string) (
                                                        $order->status
                                                        ?? ''
                                                    ))
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
PHP,
            'Work Order row Rework status and quantity'
        );

        $blade = replaceOnce(
            $blade,
            <<<'CSS'
        .status-completed {
            color: #166534;
            background: #ecfdf3;
            border: 1px solid #bbf7d0;
        }

        .status-incomplete {
CSS,
            <<<'CSS'
        .status-completed {
            color: #166534;
            background: #ecfdf3;
            border: 1px solid #bbf7d0;
        }

        .status-rework {
            min-width: 124px;
            color: #9a3412;
            background: #fff7ed;
            border: 1px solid #fdba74;
            white-space: nowrap;
        }

        .status-incomplete {
CSS,
            'Work Order Rework status styling'
        );

        $blade = replaceOnce(
            $blade,
            <<<'JS'
        function normalizeWorkOrderStatus(value) {
            return String(value || '').trim().toLowerCase() === 'completed'
                ? 'Completed'
                : 'Pending';
        }
JS,
            <<<'JS'
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
JS,
            'Work Order JavaScript Rework normalization'
        );

        $blade = replaceOnce(
            $blade,
            <<<'JS'
            if (pill) {
                pill.textContent = normalizedStatus;
                pill.classList.remove('status-pending', 'status-completed');
                pill.classList.add(normalizedStatus === 'Completed' ? 'status-completed' : 'status-pending');
            }
JS,
            <<<'JS'
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
JS,
            'Work Order JavaScript Rework badge styling'
        );
    }

    writeFileStrict($paths['blade'], $blade);

    echo "\nWork Order Rework fix applied successfully.\n";
    echo "Backup created at:\n{$backupDirectory}\n\n";
    echo "Next commands:\n";
    echo "php artisan optimize:clear\n";
    echo "php artisan view:clear\n";
    echo "php artisan cache:clear\n";
    echo "php artisan serve\n";
} catch (Throwable $exception) {
    fwrite(STDERR, "\nPatch stopped: {$exception->getMessage()}\n");
    fwrite(STDERR, "Your untouched backups are in:\n{$backupDirectory}\n");
    exit(1);
}
