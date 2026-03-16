#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# load web user
CONFIG_FILE="/root/.env"
if [ -f "$CONFIG_FILE" ]; then
    WEB_USER=$(grep "^WEB_USER=" "$CONFIG_FILE" | cut -d= -f2)
fi

if [ -z "$WEB_USER" ]; then
    if [ ! -z "$1" ]; then
        WEB_USER=$1
    else
        read -p "Enter the web user name (ex: forge): " input_user
        WEB_USER=${input_user:-"admin"}
    fi
    echo "WEB_USER=$WEB_USER" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

echo "Running as root, targeting web user: $WEB_USER"
sleep 1

install_server_stack() {
    
    if [[ $(grep -c "CONFIG_FILE=1" "$CONFIG_FILE") -ne 0 ]]; then
        echo "Server stack already installed. Skipping installation."
        return
    fi
    
    echo "--- Installing Server Stack ---"
    
    if [ ! -f /root/.my.cnf ]; then
        read -s -p "Set MySQL root password: " mysql_pass
        echo
        echo "[client]" > /root/.my.cnf
        echo "user=root" >> /root/.my.cnf
        echo "password=$mysql_pass" >> /root/.my.cnf
        chmod 600 /root/.my.cnf
    fi

    export DEBIAN_FRONTEND=noninteractive
    
    if ! command -v git >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then
        echo "Installing Utilities..."
        apt-get update || { echo "Error: apt-get update failed."; return 1; }
        apt-get install -y software-properties-common curl git unzip zip sudo || { echo "Error: Utility installation failed."; return 1; }
    fi

    if ! id "$WEB_USER" >/dev/null 2>&1; then
        echo "Creating web admin user: $WEB_USER"
        useradd -m -s /bin/bash "$WEB_USER"
        usermod -aG www-data "$WEB_USER"
    fi

    # setup web root
    mkdir -p /var/www
    chown $WEB_USER:www-data /var/www
    chmod 775 /var/www

    if ! command -v nginx >/dev/null 2>&1; then
        echo "Installing Nginx..."
        apt-get install -y nginx || { echo "Error: Nginx installation failed."; return 1; }
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        echo "Installing MySQL..."
        apt-get install -y mysql-server || { echo "Error: MySQL installation failed."; return 1; }
        echo "Configuring MySQL root password..."
        pass=$(grep password /root/.my.cnf | cut -d= -f2)
        mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$pass'; FLUSH PRIVILEGES;"
    fi

    if ! command -v redis-server >/dev/null 2>&1; then
        echo "Installing Redis..."
        apt-get install -y redis-server || { echo "Error: Redis installation failed."; return 1; }
    fi

    if ! command -v supervisorctl >/dev/null 2>&1; then
        echo "Installing Supervisor..."
        apt-get install -y supervisor || { echo "Error: Supervisor installation failed."; return 1; }
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        echo "Installing Certbot..."
        apt-get install -y certbot python3-certbot-nginx || { echo "Error: Certbot installation failed."; return 1; }
    fi

    if ! command -v node >/dev/null 2>&1; then
        echo "Installing Node.js..."
        apt-get install -y nodejs || { echo "Error: Node.js installation failed."; return 1; }
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "Installing Fail2Ban..."
        apt-get install -y fail2ban || { echo "Error: Fail2Ban installation failed."; return 1; }
        
        echo "Configuring Fail2Ban jails..."
        cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true

[nginx-badbots]
enabled = true

[mysqld-auth]
enabled = true
EOF
        systemctl enable fail2ban
        systemctl restart fail2ban
    fi

    if ! command -v php >/dev/null 2>&1; then
        echo "Installing PHP 8.3..."
        add-apt-repository -y ppa:ondrej/php || { echo "Error: PHP PPA addition failed."; return 1; }
        apt-get update
        apt-get install -y php8.3-fpm php8.3-cli php8.3-mysql php8.3-curl php8.3-gd \
            php8.3-mbstring php8.3-xml php8.3-zip php8.3-bcmath php8.3-intl php8.3-redis || { echo "Error: PHP installation failed."; return 1; }
    fi
    
    if ! command -v composer >/dev/null 2>&1; then
        echo "Installing Composer..."
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || { echo "Error: Composer installation failed."; return 1; }
    fi
    
    echo "CONFIG_FILE=1" >> "$CONFIG_FILE"
    
    echo "Server is ready!"
    read -p "Press enter to return."
}

manage_nginx_vhosts() {
    while true; do
        clear
        echo "--- Manage Nginx Vhosts ---"
        vhosts=( $(ls /etc/nginx/sites-enabled/ 2>/dev/null) )
        
        i=1
        for vhost in "${vhosts[@]}"; do
            echo "$i) $vhost"
            i=$((i+1))
        done
        
        echo "a) Create New Vhost"
        echo "0) Return to Main Menu"
        
        read -p "Choice: " choice
        if [ -z "$choice" ]; then
            continue
        fi
        
        if [ "$choice" = "0" ]; then
            return
        fi

        if [ "$choice" = "a" ]; then
            create_nginx_vhost
            continue
        fi

        # validate numeric choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "${#vhosts[@]}" ] && [ "$choice" -gt 0 ]; then
            selected="${vhosts[$((choice-1))]}"
        else
            echo "Error: Invalid choice."
            read -p "Press enter."
            continue
        fi

        while true; do
            clear
            echo "--- Manage Vhost: $selected ---"
            echo "1) Delete"
            echo "2) Disable"
            echo "3) Renew SSL"
            echo "0) Return to Vhost List"
            read -p "Option: " action

            case $action in
                1) 
                    if delete_vhost "$selected"; then
                        break
                    fi
                    ;;
                2) 
                    disable_vhost "$selected"
                    break
                    ;;
                3) renew_vhost "$selected" ;;
                0) break ;;
            esac
        done
    done
}

create_nginx_vhost() {
    clear
    echo "--- Create Nginx Vhost ---"
    echo "Select Type:"
    echo "1) Laravel Website"
    echo "2) Custom/Static Website"
    read -p "Choice: " type
    
    if [ "$type" != "1" ] && [ "$type" != "2" ]; then
        echo "Error: Invalid type."
        read -p "Press enter."
        return
    fi

    read -p "Domain (ex: domain.com): " domain
    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
    
    if [ -z "$domain" ]; then
        echo "Error: Domain is required."
        read -p "Press enter."
        return
    fi

    if [ -f "/etc/nginx/sites-available/$domain" ]; then
        echo "Error: Vhost for $domain already exists."
        read -p "Press enter."
        return
    fi

    if [ "$type" = "1" ]; then
        read -p "Public Root Path (default: /var/www/$domain/public): " root_path
        root_path=${root_path:-"/var/www/$domain/public"}
    else
        read -p "Public Root Path (default: /var/www/$domain): " root_path
        root_path=${root_path:-"/var/www/$domain"}
    fi

    if [ ! -d "$root_path" ]; then
        echo "Warning: Directory $root_path does not exist."
        read -p "Create it now? (y/n): " create_dir
        if [ "$create_dir" = "y" ]; then
            mkdir -p "$root_path"
            # fix web user permissions
            base_dir=$(echo "$root_path" | cut -d/ -f1-4)
            chown -R $WEB_USER:www-data "$base_dir"
            chmod -R 775 "$base_dir"
            echo "Directory created."
        fi
    fi

    if [ "$type" = "1" ]; then
        # laravel config
        cat > "/etc/nginx/sites-available/$domain" <<EOF
server {
    listen 80;
    server_name $domain;
    root $root_path;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
}
EOF
    else
        # custom config
        cat > "/etc/nginx/sites-available/$domain" <<EOF
server {
    listen 80;
    server_name $domain;
    root $root_path;
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
}
EOF
    fi

    ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/"
    
    if ! (nginx -t && systemctl restart nginx); then
        echo "Error: Nginx configuration is invalid. Rolling back..."
        rm -f "/etc/nginx/sites-enabled/$domain" "/etc/nginx/sites-available/$domain"
        read -p "Press enter."
        return
    fi

    echo "Vhost created successfully."
    read -p "Install SSL with Certbot? (y/n): " install_ssl
    if [ "$install_ssl" = "y" ]; then
        if ! certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email; then
            echo "Warning: Certbot failed."
        fi
    fi
    
    read -p "Done. Press enter."
}

delete_vhost() {
    local selected=$1
    echo "--- DANGER: Deleting Vhost $selected ---"
    read -p "Type the domain name to confirm: " confirm_name
    if [ "$confirm_name" != "$selected" ]; then
        echo "Error: Name mismatch. Deletion cancelled."
        read -p "Press enter."
        return 1
    fi

    # find root path
    root_path=$(grep -m 1 "root" "/etc/nginx/sites-available/$selected" | awk '{print $2}' | tr -d ';')
    
    echo "Root directory: $root_path"

    delete_files="n"
    
    if [ ! -z "$root_path" ] && [ -d "$root_path" ]; then
        read -p "Do you want to delete the website files as well? (y/n): " delete_files
    fi
    
    if [ "$delete_files" = "y" ]; then
        echo "Backing up files..."
        mkdir -p /root/backups
        backup_file="/root/backups/${selected}_$(date +%F_%H%M%S).zip"
        zip -r "$backup_file" "$root_path" > /dev/null 2>&1
        echo "Backup created at $backup_file"
        
        # remove files
        rm -rf "$root_path"
        echo "Files removed."
    fi

    # remove nginx config
    rm -rf "/etc/nginx/sites-enabled/$selected" "/etc/nginx/sites-available/$selected"
    systemctl restart nginx
    
    echo "Vhost $selected deleted."
    read -p "Done. Press enter."
    return 0
}

disable_vhost() {
    local selected=$1
    rm -rf "/etc/nginx/sites-enabled/$selected"
    systemctl restart nginx
    read -p "Done. Press enter."
    return 0
}

renew_vhost() {
    local selected=$1
    if ! certbot renew --cert-name "$selected"; then
        echo "Error: Certbot renewal failed."
    else
        echo "Done."
    fi
    read -p "Press enter."
}

manage_laravel_websites() {
    while true; do
        clear
        echo "--- Manage Laravel Websites ---"
        
        sites=( $(ls -d /var/www/*/artisan 2>/dev/null) )
        
        if [ ${#sites[@]} -eq 0 ]; then
            read -p "No Laravel sites found. Press enter."
            return
        fi

        i=1
        for site in "${sites[@]}"; do
            echo "$i) $(basename $(dirname $site))"
            i=$((i+1))
        done
        echo "0) Return to Main Menu"
        
        read -p "Choice: " choice
        if [ -z "$choice" ] || [ "$choice" -eq 0 ]; then
            return
        fi

        site_path="${sites[$((choice-1))]}"
        if [ -z "$site_path" ]; then
            echo "Error: Invalid choice."
            read -p "Press enter."
            continue
        fi

        selected=$(dirname "$site_path")
        name=$(basename "$selected")

        while true; do
            clear
            echo "--- Manage Website: $name ---"
            
            scheduler_enabled=false
            if crontab -u "$WEB_USER" -l 2>/dev/null | grep -q "cd $selected &&"; then
                scheduler_enabled=true
            fi
            
            queue_enabled=false
            if [ -f "/etc/supervisor/conf.d/$name.conf" ]; then
                queue_enabled=true
            fi

            echo "1) Pull Git Commits"
            echo "2) Update PHP Application"
            
            if [ "$scheduler_enabled" = true ]; then
                echo "3) Disable Scheduler"
            else
                echo "3) Enable Scheduler"
            fi
            
            if [ "$queue_enabled" = true ]; then
                echo "4) Disable Queue"
            else
                echo "4) Enable Queue"
            fi
            
            echo "5) Monitor"
            echo "6) Fix Permissions"
            echo "7) Delete Site"
            echo "0) Return to Site List"
            
            read -p "Action: " action
            if [ -z "$action" ]; then
                continue
            fi
            if [ "$action" -eq 0 ]; then
                break
            fi

            case $action in
                1) pull_git_commits "$selected" "$name" ;;
                2) update_site "$selected" "$name" ;;
                3) 
                    if [ "$scheduler_enabled" = true ]; then
                        disable_scheduler "$selected" "$name"
                    else
                        enable_scheduler "$selected" "$name"
                    fi
                    ;;
                4) 
                    if [ "$queue_enabled" = true ]; then
                        disable_queue "$selected" "$name"
                    else
                        enable_queue "$selected" "$name"
                    fi
                    ;;
                5) monitor_site "$selected" "$name" ;;
                6) fix_site_permissions "$selected" "$name" ;;
                7) 
                    if delete_site "$selected" "$name"; then
                        break
                    fi
                    ;;
                *) echo "Error: Invalid choice." && read -p "Press enter." ;;
            esac
        done
    done
}

pull_git_commits() {
    local selected=$1
    local name=$2
    echo "--- Git Commits: $name ---"
    sudo -u "$WEB_USER" -i bash -c "cd $selected && git fetch && git log -n 10 --oneline --decorate --graph"
    echo "---------------------------"
    read -p "Pull latest commits from $(sudo -u "$WEB_USER" -i bash -c "cd $selected && git rev-parse --abbrev-ref HEAD")? (y/n): " confirm
    
    if [[ $confirm == "y" ]]; then
        sudo -u "$WEB_USER" -i bash -c "cd $selected && git pull && composer install --no-dev --optimize-autoloader && php artisan migrate --force && php artisan optimize"
    fi

    read -p "Done. Press enter."
}

fix_site_permissions() {
    local selected=$1
    local name=$2
    echo "Fixing permissions for $name..."
    chown -R $WEB_USER:www-data "$selected" || { echo "Error: Failed to change ownership."; return 1; }
    find "$selected" -type f -exec chmod 664 {} \;
    find "$selected" -type d -exec chmod 775 {} \;
    chmod -R 775 "$selected/storage" "$selected/bootstrap/cache"
    chmod 660 "$selected/.env" 2>/dev/null
    echo "Permissions fixed."
    if [[ "$3" != "silent" ]]; then
        read -p "Press enter."
    fi
}

enable_scheduler() {
    local selected=$1
    local name=$2
    if crontab -u "$WEB_USER" -l 2>/dev/null | grep -q "cd $selected &&"; then
        echo "Scheduler already exists for $name."
    else
        (crontab -u "$WEB_USER" -l 2>/dev/null; echo "* * * * * cd $selected && php artisan schedule:run >> /dev/null 2>&1") | crontab -u "$WEB_USER" - || { echo "Error: Failed to update crontab."; return 1; }
        echo "Scheduler enabled for $name."
    fi
    read -p "Done. Press enter."
}

disable_scheduler() {
    local selected=$1
    local name=$2
    crontab -u "$WEB_USER" -l 2>/dev/null | grep -v "cd $selected &&" | crontab -u "$WEB_USER" - || { echo "Error: Failed to update crontab."; return 1; }
    echo "Scheduler disabled for $name."
    read -p "Done. Press enter."
}

enable_queue() {
    local selected=$1
    local name=$2
    cat > "/etc/supervisor/conf.d/$name.conf" <<EOF
[program:$name]
command=php $selected/artisan queue:work database --sleep=3 --tries=3
user=$WEB_USER
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/$name.log
stderr_logfile=/var/log/supervisor/$name.error.log
EOF
    if ! supervisorctl update; then
        echo "Error: supervisorctl update failed."
        rm "/etc/supervisor/conf.d/$name.conf"
        read -p "Press enter."
        return 1
    fi
    echo "Queue enabled for $name."
    read -p "Done. Press enter."
}

disable_queue() {
    local selected=$1
    local name=$2
    if [ -f "/etc/supervisor/conf.d/$name.conf" ]; then
        rm "/etc/supervisor/conf.d/$name.conf"
        if ! supervisorctl update; then
            echo "Error: supervisorctl update failed."
        else
            echo "Queue disabled for $name."
        fi
    else
        echo "Queue is not enabled for $name."
    fi
    read -p "Done. Press enter."
}

update_site() {
    local selected=$1
    local name=$2
    echo "Updating site as $WEB_USER..."
    if ! sudo -u "$WEB_USER" -i bash -c "cd $selected && git pull && composer install --no-dev --optimize-autoloader && php artisan migrate --force && php artisan optimize"; then
        echo "Error: Site update failed."
    else
        echo "Done."
    fi
    fix_site_permissions "$selected" "$name" "silent"
    read -p "Press enter."
}

monitor_site() {
    local selected=$1
    local name=$2
    script_dir=$(dirname "$(readlink -f "$0")")
    if [ -f "$script_dir/sys-watcher.sh" ]; then
        bash "$script_dir/sys-watcher.sh" "$selected"
    else
        echo "Error: sys-watcher.sh not found."
        read -p "Press enter."
    fi
}

delete_site() {
    local selected=$1
    local name=$2
    echo "--- DANGER: Deleting $name ---"
    read -p "Type the domain name to confirm: " confirm_name
    if [ "$confirm_name" != "$name" ]; then
        echo "Error: Name mismatch. Deletion cancelled."
        read -p "Press enter."
        return 1
    fi

    echo "Backing up site and database..."
    mkdir -p /root/backups
    
    db=""
    if [ -f "$selected/.env" ]; then
        db=$(grep "^DB_DATABASE=" "$selected/.env" | cut -d= -f2- | tr -d '\r' | tr -d '"' | tr -d "'")
    fi
    
    backup_file="/root/backups/${name}_$(date +%F_%H%M%S).zip"
    
    db_dumped=false

    if [ -z "$db" ]; then
        echo "No database found in .env. Proceeding with file backup only."
        db_dumped=true
    fi
    
    if [ ! -z "$db" ]; then
        if mysqldump "$db" > "/tmp/$db.sql" 2>/dev/null; then
            db_dumped=true
        fi
    fi

    if [ "$db_dumped" = false ]; then
        echo "Error: Database dump failed."
        read -p "Continue with file backup only? (y/n): " continue_choice
    fi

    if [ "$db_dumped" = false ]; then
        if [[ "$continue_choice" != "y" ]]; then
            echo "Deletion aborted."
            read -p "Press enter."
            return 1
        fi
    fi

    if [ "$db_dumped" = true ]; then
        zip -r "$backup_file" "$selected" "/tmp/$db.sql" > /dev/null 2>&1
        rm -f "/tmp/$db.sql"
    else
        zip -r "$backup_file" "$selected" > /dev/null 2>&1
    fi

    if [ ! -f "$backup_file" ]; then
         echo "Error: Backup failed. Deletion aborted."
         read -p "Press enter."
         return 1
    fi
    
    echo "Backup created at $backup_file"

    echo "Removing website files..."
    rm -rf "$selected"

    echo "Removing Nginx configuration..."
    rm -rf "/etc/nginx/sites-enabled/$name" "/etc/nginx/sites-available/$name"
    systemctl restart nginx

    if [ ! -z "$db" ]; then
        echo "Removing database and user..."
        mysql -e "DROP DATABASE IF EXISTS $db; DROP USER IF EXISTS '$db'@'localhost';"
    fi

    echo "Removing Supervisor configuration..."
    if [ -f "/etc/supervisor/conf.d/$name.conf" ]; then
        rm -rf "/etc/supervisor/conf.d/$name.conf"
        supervisorctl update
    fi

    echo "Removing Crontab entry..."
    crontab -u "$WEB_USER" -l 2>/dev/null | grep -v "cd $selected &&" | crontab -u "$WEB_USER" -

    echo "Site $name has been completely removed."
    read -p "Done. Press enter."
    return 0
}

rollback_site() {
    local domain=$1
    local db=$2
    local selected="/var/www/$domain"
    echo "Rolling back changes for $domain..."
    rm -rf "/etc/nginx/sites-enabled/$domain" "/etc/nginx/sites-available/$domain"
    rm -rf "$selected"
    if [ ! -z "$db" ]; then
        mysql -e "DROP DATABASE IF EXISTS $db; DROP USER IF EXISTS '$db'@'localhost';"
    fi
    
    if [ -f "/etc/supervisor/conf.d/$domain.conf" ]; then
        rm -rf "/etc/supervisor/conf.d/$domain.conf"
        supervisorctl update
    fi
    
    crontab -u "$WEB_USER" -l 2>/dev/null | grep -v "cd $selected &&" | crontab -u "$WEB_USER" -
    
    systemctl restart nginx
    echo "Rollback complete."
}

create_laravel_website() {
    clear
    echo "--- Create Laravel Website ---"
    while true; do
        read -p "Domain (ex: domain.com): " domain
        
        # lowercase domain
        domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')

        # strip protocol
        if [[ $domain == http://* ]]; then
            domain=${domain#http://}
        fi
        if [[ $domain == https://* ]]; then
            domain=${domain#https://}
        fi
        
        # strip path
        domain=${domain%%/*}

        if [ -z "$domain" ]; then
            echo "Error: Domain is required."
            continue
        fi

        if [ -f "/etc/nginx/sites-available/$domain" ] || [ -d "/var/www/$domain" ]; then
            echo "Error: Domain $domain already exists."
            continue
        fi
        break
    done

    while [ -z "$git_url" ]; do
        read -p "Git URL: " git_url
    done
    
    echo "Cloning repository as $WEB_USER..."
    if ! sudo -u "$WEB_USER" git clone "$git_url" "/var/www/$domain"; then
        echo "Error: Failed to clone repository."
        read -p "Press enter to return."
        return
    fi

    cat > "/etc/nginx/sites-available/$domain" <<EOF
server {
    listen 80;
    server_name $domain;
    root /var/www/$domain/public;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/"
    
    if ! (nginx -t && systemctl restart nginx); then
        echo "Error: Nginx configuration is invalid."
        rm -rf "/etc/nginx/sites-enabled/$domain" "/etc/nginx/sites-available/$domain"
        rm -rf "/var/www/$domain"
        read -p "Press enter to return."
        return
    fi

    echo "Attempting to create SSL certificate..."
    if ! certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email; then
        echo "Warning: Certbot failed to create SSL certificate."
        echo "1) Continue without SSL"
        echo "2) Abort and roll back changes"
        read -p "Choice: " ssl_choice
        if [ "$ssl_choice" != "1" ]; then
            echo "Aborting and rolling back changes..."
            rm -rf "/etc/nginx/sites-enabled/$domain" "/etc/nginx/sites-available/$domain"
            rm -rf "/var/www/$domain"
            systemctl restart nginx
            read -p "Rollback complete. Press enter."
            return
        fi
    fi
    
    selected="/var/www/$domain"
    cd "$selected" || { echo "Error: Failed to enter site directory."; rollback_site "$domain"; read -p "Press enter."; return; }
    
    db=$(echo "$domain" | tr '.-' '__')
    pass=$(openssl rand -hex 12)
    if ! mysql -e "CREATE DATABASE $db; CREATE USER '$db'@'localhost' IDENTIFIED BY '$pass'; GRANT ALL PRIVILEGES ON $db.* TO '$db'@'localhost'; FLUSH PRIVILEGES;"; then
        echo "Error: Database creation failed."
        rollback_site "$domain"
        read -p "Press enter."; return
    fi
    
    if [ ! -f .env.example ]; then
        echo "Error: .env.example not found."
        rollback_site "$domain" "$db"
        read -p "Press enter."; return
    fi

    # setup .env
    cp .env.example .env
    
    set_env_value() {
        local key=$1
        local value=$2
        local file=$3
        if grep -q "^$key=" "$file"; then
            sed -i "s|^$key=.*|$key=$value|" "$file"
        elif grep -q "^#$key=" "$file"; then
            sed -i "s|^#$key=.*|$key=$value|" "$file"
        else
            echo "$key=$value" >> "$file"
        fi
    }

    set_env_value "DB_CONNECTION" "mysql" ".env"
    set_env_value "DB_HOST" "127.0.0.1" ".env"
    set_env_value "DB_PORT" "3306" ".env"
    set_env_value "DB_DATABASE" "$db" ".env"
    set_env_value "DB_USERNAME" "$db" ".env"
    set_env_value "DB_PASSWORD" "$pass" ".env"
    set_env_value "APP_URL" "https://$domain" ".env"
    set_env_value "QUEUE_CONNECTION" "database" ".env"
    
    # fix permissions
    fix_site_permissions "$selected" "$domain" "silent"

    echo "Running composer and artisan commands as $WEB_USER..."
    if ! sudo -u "$WEB_USER" -i bash -c "cd /var/www/$domain && composer install --no-dev --optimize-autoloader && php artisan key:generate && php artisan migrate --force && php artisan storage:link"; then
        echo "Error: Application setup failed (Composer/Artisan)."
        rollback_site "$domain" "$db"
        read -p "Press enter."; return
    fi
    
    echo "Site created!"
    echo "Database: $db"
    echo "DB User: $db"
    echo "DB Password: $pass"
    read -p "Press enter to return."
}

manage_fail2ban() {
    while true; do
        clear
        echo "--- Manage Fail2Ban ---"
        echo "1) Show Overall Status"
        echo "2) Show SSH Jail Status (Banned IPs)"
        echo "3) Ban an IP"
        echo "4) Unban an IP"
        echo "0) Return to Main Menu"
        read -p "Choice: " choice
        
        case $choice in
            1)
                fail2ban-client status
                read -p "Press enter."
                ;;
            2)
                fail2ban-client status sshd
                read -p "Press enter."
                ;;
            3)
                read -p "IP to ban: " ip
                if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    echo "Error: Invalid IP format."
                    read -p "Press enter."
                    continue
                fi
                read -p "Jail (default: sshd): " jail
                jail=${jail:-"sshd"}
                fail2ban-client set "$jail" banip "$ip"
                read -p "Done. Press enter."
                ;;
            4)
                read -p "IP to unban: " ip
                if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    echo "Error: Invalid IP format."
                    read -p "Press enter."
                    continue
                fi
                read -p "Jail (default: sshd): " jail
                jail=${jail:-"sshd"}
                fail2ban-client set "$jail" unbanip "$ip"
                read -p "Done. Press enter."
                ;;
            0)
                return
                ;;
            *)
                echo "Invalid choice."
                sleep 1
                ;;
        esac
    done
}

while true; do
    clear
    echo "--- Laravel Server Manager ($WEB_USER) ---"

    if [[ $(grep -c "CONFIG_FILE=1" "$CONFIG_FILE") -eq 0 ]]; then
        echo "1) Install Server Stack"
        echo "2) Exit"
        read -p "Choice: " choice
        case $choice in
            1) install_server_stack ;;
            2) exit 0 ;;
            *) echo "Invalid choice."; sleep 1 ;;
        esac
        continue
    fi
    
    echo "1) Manage Nginx Vhosts"
    echo "2) Manage Laravel Websites"
    echo "3) Create Laravel Website"
    echo "4) Manage Fail2Ban"
    echo "5) Exit"
    read -p "Choice: " choice
    case $choice in
        1) manage_nginx_vhosts ;;
        2) manage_laravel_websites ;;
        3) create_laravel_website ;;
        4) manage_fail2ban ;;
        5) exit 0 ;;
        *) echo "Invalid choice."; sleep 1 ;;
    esac
done
