#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 laravel_project_path" >&2
    exit 1
fi

LARAVEL_PROJECT_PATH="$1"

if [ ! -f "$LARAVEL_PROJECT_PATH/artisan" ]; then
    echo "Error: Invalid Laravel project path." >&2
    exit 1
fi

cd "$LARAVEL_PROJECT_PATH"

FAILED_ROUTES_JSON=$(php <<EOF
<?php
putenv('LOG_CHANNEL=null');
require 'vendor/autoload.php';
\$app = require_once 'bootstrap/app.php';
\$kernel = \$app->make(Illuminate\Contracts\Console\Kernel::class);
\$kernel->bootstrap();

use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

config(['logging.default' => 'null']);
\$lastError = null;

Log::listen(function () {
    \$args = func_get_args();
    \$event = \$args[0];
    \$level = is_object(\$event) ? \$event->level : \$args[0];
    \$message = is_object(\$event) ? \$event->message : (\$args[1] ?? 'Unknown');
    \$context = is_object(\$event) ? \$event->context : (\$args[2] ?? []);

    if (in_array(\$level, ['error', 'critical', 'alert', 'emergency'])) {
        global \$lastError;
        \$stack = (isset(\$context['exception']) && \$context['exception'] instanceof \Throwable) 
            ? "\nStack Trace:\n" . \$context['exception']->getTraceAsString() : '';
        \$lastError = "[\$level] \$message" . \$stack;
    }
});

\$version = app()->version();
\$isLaravel12 = version_compare(\$version, '12.0.0', '>=');

\$results = collect(app('router')->getRoutes())
    ->reject(function (\$route) {
        return Str::contains(\$route->uri(), '{') || Str::startsWith(\$route->uri(), ['_', 'sanctum', 'broadcasting']);
    })
    ->flatMap(function (\$route) {
        return collect(\$route->methods())->diff(['HEAD', 'OPTIONS'])->map(function (\$method) use (\$route) {
            return ['method' => \$method, 'uri' => '/' . ltrim(\$route->uri(), '/')];
        });
    })
    ->map(function (\$item) use (\$isLaravel12) {
        global \$lastError;
        \$lastError = null;
        try {
            \$request = Illuminate\Http\Request::create(\$item['uri'], \$item['method']);
            \$response = app()->handle(\$request);
            \$status = \$response->getStatusCode();
            
            // Rejection logic: 2xx, 3xx, 419 (CSRF), and 422 (Validation) are not "failures"
            return array_merge(\$item, ['status' => \$status, 'error' => \$lastError]);
        } catch (\Throwable \$e) {
            return array_merge(\$item, ['status' => 'EXCEPTION', 'error' => \$e->getMessage()]);
        }
    })
    ->reject(function (\$result) {
        \$status = \$result['status'];
        return (\$status >= 200 && \$status < 400) || \$status == 419 || \$status == 422;
    })
    ->values();

echo \$results->toJson();
EOF
)

echo "$FAILED_ROUTES_JSON"
