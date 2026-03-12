#!/bin/bash

# configuration
API_URL=""
API_TOKEN=""
composer_file=/TMP_DIR/composer.json
base_dir=$(dirname "${composer_file}")

echo "Checking $composer_file for laravel/framework dependency..."

if [[ ! $(grep -a 'laravel/framework' $composer_file) ]]; then
    exit 1
fi

log_type=$(grep -a 'LOG_CHANNEL=' "$base_dir/.env" | head -n 1 | cut -d '=' -f 2)

if [[ -z "$log_type" ]]; then
    log_type="stack"
fi

case "$log_type" in
    "stack"|"single")
        log_file="$base_dir/storage/logs/laravel.log"
        ;;
    "daily")
        log_file="$base_dir/storage/logs/laravel-$(date +%Y-%m-%d).log"
        ;;
    *)
        echo "Unsupported LOG_CHANNEL: $log_type"
        exit 1
        ;;
esac

if [[ ! -f "$log_file" ]]; then
    echo "Log file $log_file does not exist."
    exit 1
fi

# helper function to count errors on 
count_error_type() {
    local type=$1
    local file=$2
    count=$(grep -c "\.${type}:" "$file")
    echo $count
}

printf "\n%s\n" "------------------------------------------------------------------------------------------------"
printf " Monitoring Started (%s): %-30s\n" "$log_type" "$log_file"
printf "%s\n" "------------------------------------------------------------------------------------------------"

# initialize line counter to the current end of the file
last_line=$(wc -l < "$log_file")

while true; do

    current_line_count=$(wc -l < "$log_file")

    # if the file hasn't grown, wait and skip
    if [[ "$current_line_count" -le "$last_line" ]]; then
        # if the file was truncated
        if [[ "$current_line_count" -lt "$last_line" ]]; then
            last_line=$current_line_count
        fi
        sleep 3
        continue
    fi

    # just in case we still in the same spot
    if [[ "$start_line" == "$current_line_count" ]]; then
        sleep 3
        continue
    fi

    start_line=$((last_line + 1))

    # laravel
    line=$(sed -n "${start_line},${current_line_count}p" "$log_file")
    failed_queue_jobs=$(php "$base_dir/artisan" queue:failed 2>/dev/null | wc -l | awk '{print ($1 >= 5) ? $1 - 5 : 0}')
    count_debug=$(grep -c "\.DEBUG:" "$log_file")
    count_info=$(grep -c "\.INFO:" "$log_file")
    count_notice=$(grep -c "\.NOTICE:" "$log_file")
    count_warning=$(grep -c "\.WARNING:" "$log_file")
    count_error=$(grep -c "\.ERROR:" "$log_file")
    count_critical=$(grep -c "\.CRITICAL:" "$log_file")
    count_alert=$(grep -c "\.ALERT:" "$log_file")
    count_emergency=$(grep -c "\.EMERGENCY:" "$log_file")

    cpu_usage=$(top -n1 | grep "%Cpu(s):" | awk '{printf("%.0f", 100 - $8)}')
    mem_usage=$(top -n1 | grep "MiB Mem :" | awk '{printf("%.0f", $8/$4 * 100)}')
    disk_usage=$(df -h --type="ext4" | tail -n 1 | awk '{print $5}' | tr -d '%')
    active_processes=$(ps -e --sort=-pcpu -o pid,pcpu,pmem,comm | head -n 2 | tail -n 1 | awk '{printf "PID: %s | CPU: %s%% | MEM: %s%% | CMD: %s", $1, $2, $3, $4}')
    active_http_conns=$(netstat -an | grep -E ':80|:443' | grep ESTABLISHED | wc -l)

    redis_mem_usage="N/A"
    redis_clients="N/A"
    if command -v redis-cli > /dev/null 2>&1; then
        redis_mem_usage=$(redis-cli info memory | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
        redis_clients=$(redis-cli info clients | grep "connected_clients" | cut -d: -f2 | tr -d '\r')
    fi
    
    mysql_cpu=$(ps aux | grep mysqld | grep -v grep | awk '{print $3"%"}')
    mysql_memory=$(ps aux | grep mysqld | grep -v grep | awk '{print $4"%"}')

    fpm_active=$(ps aux | grep "php-fpm: pool" | grep -v "grep" | wc -l)

    # formatting terminal output
    printf "\n\033[1;33m[%s]\033[0m\n" "NEW LOG ENTRY DETECTED"
    printf "%-12s : %s active pools\n" "PHP" "$fpm_active"
    printf "%-12s : CPU: %-5s | RAM: %s\n" "MYSQL" "$mysql_cpu" "$mysql_memory"
    printf "%-12s : Mem: %-5s | Clients: %s\n" "REDIS" "$redis_mem_usage" "$redis_clients"
    printf "%-12s : CPU: %s%% | RAM: %s%% | Disk: %s%%\n" "SYSTEM" "$cpu_usage" "$mem_usage" "$disk_usage"
    printf "%-12s : %.60s\n" "TOP PROC" "$active_processes"
    printf "%-12s : %s\n" "NETWORK" "Active HTTP: $active_http_conns"
    printf "%-12s : %s\n" "LARAVEL" "Failed Jobs: ${failed_queue_jobs}"
    printf "%-12s : ERR: %-4s | CRT: %-4s | ALR: %-4s | EMG: %-4s\n" "CRITICALS" "$count_error" "$count_critical" "$count_alert" "$count_emergency"
    printf "%-12s : DBG: %-4s | INF: %-4s | NTC: %-4s | WRN: %-4s\n" "GENERAL" "$count_debug" "$count_info" "$count_notice" "$count_warning"
    printf "%-12s : %.250s...\n" "LOG MESSAGE" "$line"
    printf "%s\n" "------------------------------------------------------------------------------------------------"

    if [[ ! -z $API_URL ]]; then
    
        json_payload=$(cat <<EOF
{
    "log_message": "$line",
    "laravel": {
        "failed_jobs": "$failed_queue_jobs"
        "errors_count": {
            "debug": "$count_debug",
            "info": "$count_info",
            "notice": "$count_notice",
            "warning": "$count_warning",
            "error": "$count_error",
            "critical": "$count_critical",
            "alert": "$count_alert",
            "emergency": "$count_emergency"
        }
    },
    "php": {
        "fpm_active_pools": "$fpm_active"
    },
    "mysql": {
        "cpu": "$mysql_cpu",
        "memory": "$mysql_memory"
    },
    "redis": {
        "memory_usage": "$redis_mem_usage",
        "connected_clients": "$redis_clients"
    },
    "system": {
        "cpu_load": "$cpu_usage",
        "ram_usage": "$mem_usage",
        "disk_usage": "$disk_usage",
        "top_process": "$active_processes"
    },
    "network": {
        "http_connections": "$active_http_conns"
    }
}
EOF
)

        # base64 encode and send
        b64_payload=$(echo -n "$json_payload" | base64 | tr -d '\n')

        curl -s -X POST "$API_URL" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"payload\": \"$b64_payload\"}" > /dev/null

    fi


done
