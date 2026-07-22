@php
    use Illuminate\Support\Facades\Blade;

    /*
        Die Mold Machine 30 — Spot Weld

        This view renders the complete Machine 29 page as the shared Die Mold
        machine template, then replaces only the machine-specific information.
        All layout, filters, calculations, charts, activity records, and other
        existing functionality remain exactly the same as the reference page.
    */

    $referenceViewPath = resource_path(
        'views/discover/die-mold/die-mold-machine29.blade.php'
    );

    if (! file_exists($referenceViewPath)) {
        abort(500, 'The Die Mold Machine 29 reference Blade was not found.');
    }

    $machine30Template = file_get_contents($referenceViewPath);

    if ($machine30Template === false) {
        abort(500, 'The Die Mold Machine 29 reference Blade could not be read.');
    }

    $machine30Template = str_replace(
        [
            "Die Mold Machine 29",
            "'machineNumber' => 29",
            "NHM-GR-04",
            "GRINDING MACHINE W/ DUST COLLECTOR & COOLANT",
            "'KURODA'",
            "'GRINDING'",
            "photos/Surface Grinder- Machine 1.png",
            "die-mold-machine29-production-date-filter",
            "{{ \$machineManufacturer }}, with asset number",
        ],
        [
            "Die Mold Machine 30",
            "'machineNumber' => 30",
            "NHM-SW-01",
            "SPOT WELD",
            "'CHUO'",
            "'SPOT WELDING'",
            "photos/Spot Weld.png",
            "die-mold-machine30-production-date-filter",
            "{{ \$machineManufacturer }}, model {{ \$machineModel }}, serial number N/A, with asset number",
        ],
        $machine30Template
    );
@endphp

{!! Blade::render($machine30Template, get_defined_vars()) !!}
