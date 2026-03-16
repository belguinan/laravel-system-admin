#!/bin/bash

# configuration
API_URL=""
API_TOKEN=""

# Accept base directory as first argument
base_dir="${1:-/var/www/html}"
composer_file="${base_dir}/composer.json"

if [[ ! -d "$base_dir" ]]; then
    echo "Error: Directory $base_dir does not exist."
    exit 1
fi

cd "$base_dir" || exit 1

if [[ ! -r "$composer_file" ]] || [[ ! -r ".env" ]] || [[ ! -r "artisan" ]]; then
    echo "Error: Missing required Laravel files in $base_dir."
    exit 1
fi

log_type=$(grep -a 'LOG_CHANNEL=' ".env" | head -n 1 | cut -d '=' -f 2 | tr -d '\r')
[ -z "$log_type" ] && log_type="stack"

case "$log_type" in
    "stack"|"single") log_file="storage/logs/laravel.log" ;;
    "daily") log_file="storage/logs/laravel-$(date +%Y-%m-%d).log" ;;
    *) log_file="storage/logs/laravel.log" ;;
esac

# fallback to daily if not found
if [[ ! -f "$log_file" ]]; then
    log_file="storage/logs/laravel-$(date +%Y-%m-%d).log"
fi

if [[ ! -f "$log_file" ]]; then
    touch "storage/logs/laravel.log"
    log_file="storage/logs/laravel.log"
fi

last_line=$(wc -l < "$log_file")
loop_count=0
routes_json="[]"
failed_routes_count=0
latest_log_entry="No new entries."

clear

while true; do
    # update log entries
    current_line_count=$(wc -l < "$log_file")
    if [[ "$current_line_count" -gt "$last_line" ]]; then
        new_lines=$(sed -n "$((last_line + 1)),${current_line_count}p" "$log_file")
        latest_log_entry=$(echo "$new_lines" | tail -n 5)
        last_line=$current_line_count
    elif [[ "$current_line_count" -lt "$last_line" ]]; then
        last_line=$current_line_count
    fi

    # system metrics
    cpu_usage=$(top -bn1 2>/dev/null | grep "%Cpu(s):" | awk '{printf("%.0f", 100 - $8)}')
    mem_usage=$(free -m 2>/dev/null | awk '/^Mem:/ {printf("%.0f", $3/$2 * 100)}')
    disk_usage=$(df -h . | tail -n 1 | awk '{print $5}' | tr -d '%')
    active_http=$(netstat -an 2>/dev/null | grep -E ':80|:443' | grep -c ESTABLISHED)
    
    # process data
    top_proc=$(ps -e --sort=-pcpu -o pid,pcpu,comm | awk 'NR==2 {print $1, $2, $3}')
    read -r t_pid t_cpu t_cmd <<< "$top_proc"

    # mysql & redis
    mysql_cpu=$(ps aux | awk '/[m]ysqld/ {print $3"%"; exit}')
    mysql_mem=$(ps aux | awk '/[m]ysqld/ {print $4"%"; exit}')
    redis_mem="0"
    redis_clients="0"
    if command -v redis-cli > /dev/null 2>&1; then
        redis_mem=$(redis-cli info memory 2>/dev/null | grep "^used_memory_human:" | cut -d: -f2 | tr -d '\r')
        redis_clients=$(redis-cli info clients 2>/dev/null | grep "^connected_clients:" | cut -d: -f2 | tr -d '\r')
    fi

    # php-fpm
    fpm_active=$(ps aux | grep -c "php-fpm: pool")

    # laravel metrics
    failed_jobs=0
    if [ -f "artisan" ]; then
        failed_jobs=$(php artisan queue:failed 2>/dev/null | grep -c "^|" | awk '{print ($1 > 0) ? $1 : 0}')
    fi
    
    # route analysis every 10 loops
    if [[ $((loop_count % 10)) -eq 0 ]]; then
        script_dir=$(dirname "$(readlink -f "$0")")
        if [ -f "$script_dir/routes-anaylzer.sh" ]; then
            routes_json=$("$script_dir/routes-anaylzer.sh" "$base_dir" 2>/dev/null)
            failed_routes_count=$(echo "$routes_json" | php -r "\$d=json_decode(file_get_contents('php://stdin'),true);echo is_array(\$d)?count(\$d):0;")
        fi
    fi

    # log stats
    log_tail=$(tail -n 100 "$log_file")
    c_dbg=$(echo "$log_tail" | grep -c "\.DEBUG:")
    c_inf=$(echo "$log_tail" | grep -c "\.INFO:")
    c_ntc=$(echo "$log_tail" | grep -c "\.NOTICE:")
    c_wrn=$(echo "$log_tail" | grep -c "\.WARNING:")
    c_err=$(echo "$log_tail" | grep -c "\.ERROR:")
    c_crt=$(echo "$log_tail" | grep -c "\.CRITICAL:")
    c_alt=$(echo "$log_tail" | grep -c "\.ALERT:")
    c_emg=$(echo "$log_tail" | grep -c "\.EMERGENCY:")

    # display dashboard
    clear
    printf "\033[1;32mLaravel Site Monitor - %s\033[0m\n" "$base_dir"
    printf "==============================================================================\n"
    printf "SYSTEM   | CPU: %s%% | RAM: %s%% | DISK: %s%% | HTTP: %s\n" "${cpu_usage:-0}" "${mem_usage:-0}" "${disk_usage:-0}" "${active_http:-0}"
    printf "SERVICES | MySQL CPU: %s, RAM: %s | Redis MEM: %s | FPM: %s\n" "${mysql_cpu:-0%}" "${mysql_mem:-0%}" "${redis_mem:-0}" "$fpm_active"
    printf "LARAVEL  | FAILED JOBS: %s | FAILED ROUTES: %s\n" "$failed_jobs" "$failed_routes_count"
    printf "LOGS(100)| ERRORS: %s | CRITICAL: %s | EMERGENCY: %s\n" "$c_err" "$c_crt" "$c_emg"
    printf "------------------------------------------------------------------------------\n"
    printf "\033[1;33mLATEST LOG ENTRY:\033[0m\n"
    echo "$latest_log_entry" | fold -w 78 -s | tail -n 3
    printf "==============================================================================\n"

    # API reporting
    if [[ ! -z $API_URL ]]; then
    
        # simple cleanup for JSON
        raw_log=$(echo "$latest_log_entry" | tail -n 1 | tr -d '\n\r')

        # param expensinon can cause issues with quotes, so we escape them
        safe_log=${raw_log//\"/\\\"}
        
        json_payload=$(cat <<EOF
{
    "log_message": "$safe_log",
    "laravel": {
        "failed_jobs": "$failed_jobs",
        "failed_routes": "$failed_routes_count",
        "errors_count": {
            "debug": "$c_dbg",
            "info": "$c_inf",
            "notice": "$c_ntc",
            "warning": "$c_wrn",
            "error": "$c_err",
            "critical": "$c_crt",
            "alert": "$c_alt",
            "emergency": "$c_emg"
        }
    },
    "php": {
        "fpm_active_pools": "$fpm_active"
    },
    "mysql": {
        "cpu": "$mysql_cpu",
        "memory": "$mysql_mem"
    },
    "redis": {
        "memory_usage": "$redis_mem",
        "connected_clients": "$redis_clients"
    },
    "system": {
        "cpu_load": "$cpu_usage",
        "ram_usage": "$mem_usage",
        "disk_usage": "$disk_usage",
        "top_process": "$t_cmd ($t_cpu%)"
    },
    "network": {
        "http_connections": "$active_http"
    }
}
EOF
)
        curl -s -X POST "$API_URL" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$json_payload" > /dev/null
    fi

    loop_count=$((loop_count + 1))
    sleep 3
done
