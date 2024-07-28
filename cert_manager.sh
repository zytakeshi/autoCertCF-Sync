#!/bin/bash

# Determine the base directory dynamically
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define file paths
CONFIG_FILE="$BASE_DIR/config.sh"
AUTH_HOOK_SCRIPT="$BASE_DIR/auth-hook-script.sh"
RENEW_DEPLOY_SCRIPT="$BASE_DIR/renew_and_deploy.sh"
MAIN_SCRIPT="$BASE_DIR/cert_main.sh"
LOG_FILE="$BASE_DIR/cert_management.log"

# Create necessary directories and set permissions
mkdir -p $BASE_DIR
chmod 700 $BASE_DIR

# Utility Functions

log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR" "$1"
        exit 1
    fi
}

install_package() {
    if [ -x "$(command -v apt-get)" ]; then
        sudo apt-get update
        sudo apt-get install -y "$1"
    elif [ -x "$(command -v yum)" ]; then
        sudo yum install -y "$1"
    elif [ -x "$(command -v dnf)" ]; then
        sudo dnf install -y "$1"
    elif [ -x "$(command -v zypper)" ]; then
        sudo zypper install -y "$1"
    else
        log "ERROR" "无法安装 $1. 请手动安装."
        exit 1
    fi
}

check_and_install_dependencies() {
    for pkg in certbot curl jq; do
        if ! command -v $pkg &> /dev/null; then
            log "INFO" "$pkg 未安装. 正在安装..."
            install_package $pkg
        fi
    done
}

check_cloudflare_api_version() {
    local API_VERSION=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $CF_API_KEY" \
        -H "Content-Type: application/json" | jq -r '.result.tokens.version')
    
    if [[ "$API_VERSION" != "v4" ]]; then
        log "WARNING" "Cloudflare API version mismatch. Expected v4, got $API_VERSION"
    fi
}

check_certbot_version() {
    local REQUIRED_VERSION="1.0.0"
    local CURRENT_VERSION=$(certbot --version 2>&1 | grep -oP "(\d+\.)+\d+")
    
    if ! command -v certbot &> /dev/null || [ "$(printf '%s\n' "$REQUIRED_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
        log "ERROR" "Certbot version $REQUIRED_VERSION or higher is required."
        exit 1
    fi
}

check_ssh_access() {
    local remote=$1
    ssh -o BatchMode=yes -o ConnectTimeout=5 $remote exit &>/dev/null
    if [ $? -ne 0 ]; then
        log "ERROR" "Cannot connect to $remote. Please ensure SSH key-based authentication is set up."
        return 1
    fi
    return 0
}

add_cron_job() {
    local cron_job="$1"
    (crontab -l 2>/dev/null | grep -Fv "$cron_job"; echo "$cron_job") | crontab -
}

update_config() {
    local key="$1"
    local value="$2"
    sed -i "s|^$key=.*|$key=\"$value\"|" "$CONFIG_FILE"
}

# Configuration Setup

if [ ! -f $CONFIG_FILE ]; then
    log "INFO" "Creating new configuration file..."
    
    read -p "请输入你的 Cloudflare API 密钥： " CF_API_KEY
    read -p "请输入你的 Cloudflare API 电子邮件： " CF_API_EMAIL
    read -p "请输入你的域名 (例如 example.com)： " DOMAIN
    read -p "请输入保存证书的目录 (例如 /var/www/html/downloads/cert/ocserv)： " CERT_DIR
    read -p "请输入远程节点服务器 (逗号分隔，例如 node1.example.com,node2.example.com)： " NODE_SERVERS
    read -p "请输入远程服务器上证书文件的文件名 (例如 server-cert.pem)： " REMOTE_CERT_FILE
    read -p "请输入远程服务器上私钥文件的文件名 (例如 server-key.pem)： " REMOTE_KEY_FILE
    read -p "请输入远程服务器上保存证书的目录 (例如 /root/cert/ocserv)： " REMOTE_CERT_DIR
    read -p "是否使用通配符证书？ (y/n): " USE_WILDCARD
    read -p "DNS 传播等待时间 (秒)： " DNS_WAIT_TIME

    WILDCARD=$([ "$USE_WILDCARD" = "y" ] && echo "true" || echo "false")

    cat << EOF > $CONFIG_FILE
# config.sh

# Domain for which to obtain the certificate
DOMAIN="$DOMAIN"

# Cloudflare API details
CF_API_EMAIL="$CF_API_EMAIL"
export CF_API_KEY="$CF_API_KEY"

# Directory for saving certificates
CERT_DIR="$CERT_DIR"

# Remote node servers
NODE_SERVERS="$NODE_SERVERS"

# Remote certificate file name
REMOTE_CERT_FILE="$REMOTE_CERT_FILE"

# Remote private key file name
REMOTE_KEY_FILE="$REMOTE_KEY_FILE"

# Directory to save certificates on remote servers
REMOTE_CERT_DIR="$REMOTE_CERT_DIR"

# Use wildcard certificate
WILDCARD=$WILDCARD

# DNS propagation wait time
DNS_WAIT_TIME=$DNS_WAIT_TIME

# Log file location
LOG_FILE="$LOG_FILE"
EOF
    chmod 600 $CONFIG_FILE
fi

# Source the configuration file
source $CONFIG_FILE

# Create the auth hook script
cat << EOF > $AUTH_HOOK_SCRIPT
#!/bin/bash
DOMAIN=\$CERTBOT_DOMAIN
TOKEN_VALUE=\$CERTBOT_VALIDATION
source $CONFIG_FILE

CF_ZONE_ID=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=\$DOMAIN" \\
        -H "X-Auth-Email: \$CF_API_EMAIL" \\
        -H "Authorization: Bearer \$CF_API_KEY" \\
        -H "Content-Type: application/json" | jq -r '.result[0].id')

RECORD_NAME="_acme-challenge.\$DOMAIN"

log "DEBUG" "DOMAIN: \$DOMAIN"
log "DEBUG" "TOKEN_VALUE: \$TOKEN_VALUE"
log "DEBUG" "CF_ZONE_ID: \$CF_ZONE_ID"
log "DEBUG" "RECORD_NAME: \$RECORD_NAME"

# Find existing record if it exists
RECORD_ID=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/\$CF_ZONE_ID/dns_records?type=TXT&name=\$RECORD_NAME" \\
    -H "X-Auth-Email: \$CF_API_EMAIL" \\
    -H "Authorization: Bearer \$CF_API_KEY" \\
    -H "Content-Type: application/json" | jq -r '.result[0].id')

log "DEBUG" "RECORD_ID: \$RECORD_ID"

if [ "\$RECORD_ID" != "null" ] && [ -n "\$RECORD_ID" ]; then
    # Update existing record
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/\$CF_ZONE_ID/dns_records/\$RECORD_ID" \\
        -H "X-Auth-Email: \$CF_API_EMAIL" \\
        -H "Authorization: Bearer \$CF_API_KEY" \\
        -H "Content-Type: application/json" \\
        --data '{"type":"TXT","name":"'\$RECORD_NAME'","content":"'\$TOKEN_VALUE'","ttl":120}'
else
    # Create new record
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/\$CF_ZONE_ID/dns_records" \\
        -H "X-Auth-Email: \$CF_API_EMAIL" \\
        -H "Authorization: Bearer \$CF_API_KEY" \\
        -H "Content-Type: application/json" \\
        --data '{"type":"TXT","name":"'\$RECORD_NAME'","content":"'\$TOKEN_VALUE'","ttl":120}'
fi

log "INFO" "Waiting \$DNS_WAIT_TIME seconds for DNS propagation..."
sleep \$DNS_WAIT_TIME
EOF
chmod +x $AUTH_HOOK_SCRIPT

# Create the renewal and deployment script
cat << EOF > $RENEW_DEPLOY_SCRIPT
#!/bin/bash
source $CONFIG_FILE

log "INFO" "Starting certificate renewal and deployment"

if [ "\$WILDCARD" = true ]; then
    DOMAIN_PARAM="-d *.\$DOMAIN"
else
    DOMAIN_PARAM="-d \$DOMAIN"
fi

# Obtain the certificate using certbot and dns-01 challenge
certbot certonly --manual --preferred-challenges dns-01 --manual-auth-hook $AUTH_HOOK_SCRIPT --manual-cleanup-hook "echo 'Cleanup not needed for Cloudflare'" \$DOMAIN_PARAM --agree-tos -m "\$CF_API_EMAIL" --non-interactive --expand
check_error "Failed to obtain certificate"

# Move the certificates to the desired location and rename them
CERT_PATH="/etc/letsencrypt/live/\$DOMAIN"
cp "\$CERT_PATH/fullchain.pem" "\$CERT_DIR/\$REMOTE_CERT_FILE"
cp "\$CERT_PATH/privkey.pem" "\$CERT_DIR/\$REMOTE_KEY_FILE"
check_error "Failed to copy certificates to \$CERT_DIR"

log "INFO" "证书和密钥已保存到 \$CERT_DIR"

# Copy the certificates to each remote machine
IFS=',' read -ra NODES <<< "\$NODE_SERVERS"
for remote in "\${NODES[@]}"; do
    if check_ssh_access "root@\$remote"; then
        scp -o StrictHostKeyChecking=no "\$CERT_DIR/\$REMOTE_CERT_FILE" "\$CERT_DIR/\$REMOTE_KEY_FILE" "root@\$remote:\$REMOTE_CERT_DIR/"
        check_error "Failed to copy certificates to \$remote"
    fi
done

log "INFO" "证书已复制到远程服务器"
EOF
chmod +x $RENEW_DEPLOY_SCRIPT

# Create the main script
cat << EOF > $MAIN_SCRIPT
#!/bin/bash
source $CONFIG_FILE

log "INFO" "Starting SSL certificate management script"

check_and_install_dependencies
check_cloudflare_api_version
check_certbot_version

# Function to update the domain in the certbot renewal configuration file
update_certbot_renewal_conf() {
    local NEW_DOMAIN=\$1
    local CONF_FILE="/etc/letsencrypt/renewal/\${NEW_DOMAIN}.conf"
    
    if [ -f "\$CONF_FILE" ]; then
        sed -i "s/^domains = .*/domains = *.\$NEW_DOMAIN/" "\$CONF_FILE"
        log "INFO" "Updated certbot renewal configuration for \$NEW_DOMAIN"
    else
        log "WARNING" "Certbot renewal configuration file not found for \$NEW_DOMAIN"
    fi
}

# Function to check if the certificate is due for renewal
is_certificate_due_for_renewal() {
    local DOMAIN=\$1
    local EXPIRY_DATE=\$(certbot certificates --domain "\$DOMAIN" | grep "Expiry Date" | awk -F ': ' '{print \$2}')
    
    if [ -z "\$EXPIRY_DATE" ]; then
        log "INFO" "未找到 \$DOMAIN 的现有证书"
        return 0  # No existing certificate, so it needs to be obtained
    fi
    
    local EXPIRY_TIMESTAMP=\$(date -d "\$EXPIRY_DATE" +%s)
    local CURRENT_TIMESTAMP=\$(date +%s)
    local THIRTY_DAYS_IN_SECONDS=\$((30 * 24 * 60 * 60))
    
    if [ \$((EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP)) -le \$THIRTY_DAYS_IN_SECONDS ]; then
        log "INFO" "证书 \$DOMAIN 需要续订"
        return 0  # Certificate is due for renewal
    else
        log "INFO" "证书 \$DOMAIN 不需要续订"
        return 1  # Certificate is not due for renewal
    fi
}

# Check if the certificate is due for renewal
if ! is_certificate_due_for_renewal "\$DOMAIN"; then
    log "INFO" "跳过证书续订"
    exit 0
fi

# Get the Zone ID for the domain
CF_ZONE_ID=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=\$DOMAIN" \\
        -H "X-Auth-Email: \$CF_API_EMAIL" \\
        -H "Authorization: Bearer \$CF_API_KEY" \\
        -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "\$CF_ZONE_ID" == "null" ] || [ -z "\$CF_ZONE_ID" ]; then
    log "ERROR" "无法检索区域 ID。请检查你的 Cloudflare 凭据和域名"
    exit 1
fi

log "INFO" "使用 CF_ZONE_ID: \$CF_ZONE_ID"

# Ensure the directory exists
mkdir -p "\$CERT_DIR"

# Run the renewal and deployment script
$RENEW_DEPLOY_SCRIPT

# Update certbot renewal configuration file
update_certbot_renewal_conf "\$DOMAIN"

# Add a cron job for automatic renewal
CRON_JOB="0 0 1 * * $RENEW_DEPLOY_SCRIPT"
add_cron_job "\$CRON_JOB"

log "INFO" "自动续订 cron 任务已添加"
log "INFO" "SSL certificate management script completed successfully"
EOF
chmod +x $MAIN_SCRIPT

# Prompt user for action
echo "请选择一个操作："
echo "1. 发行/续订证书"
echo "2. 列出证书"
echo "3. 删除证书"
echo "4. 更新配置"
read ACTION

case $ACTION in
    1)
        $MAIN_SCRIPT
        ;;
    2)
        certbot certificates
        ;;
    3)
        echo "请输入要删除的域名 (例如 example.com)："
        read DELETE_DOMAIN
        certbot delete --cert-name $DELETE_DOMAIN
        check_error "Failed to delete certificate for $DELETE_DOMAIN"
        log "INFO" "已删除 $DELETE_DOMAIN 的证书"
        ;;
    4)
        echo "请选择要更新的配置项："
        echo "1. 域名"
        echo "2. Cloudflare API 邮箱"
        echo "3. Cloudflare API 密钥"
        echo "4. 证书保存目录"
        echo "5. 远程节点服务器"
        echo "6. 远程证书文件名"
        echo "7. 远程私钥文件名"
        echo "8. 远程证书保存目录"
        echo "9. 使用通配符证书"
        echo "10. DNS 传播等待时间"
        read CONFIG_OPTION

        case $CONFIG_OPTION in
            1)
                read -p "新域名: " NEW_VALUE
                update_config "DOMAIN" "$NEW_VALUE"
                ;;
            2)
                read -p "新 Cloudflare API 邮箱: " NEW_VALUE
                update_config "CF_API_EMAIL" "$NEW_VALUE"
                ;;
            3)
                read -p "新 Cloudflare API 密钥: " NEW_VALUE
                update_config "CF_API_KEY" "$NEW_VALUE"
                ;;
            4)
                read -p "新证书保存目录: " NEW_VALUE
                update_config "CERT_DIR" "$NEW_VALUE"
                ;;
            5)
                read -p "新远程节点服务器 (逗号分隔): " NEW_VALUE
                update_config "NODE_SERVERS" "$NEW_VALUE"
                ;;
            6)
                read -p "新远程证书文件名: " NEW_VALUE
                update_config "REMOTE_CERT_FILE" "$NEW_VALUE"
                ;;
            7)
                read -p "新远程私钥文件名: " NEW_VALUE
                update_config "REMOTE_KEY_FILE" "$NEW_VALUE"
                ;;
            8)
                read -p "新远程证书保存目录: " NEW_VALUE
                update_config "REMOTE_CERT_DIR" "$NEW_VALUE"
                ;;
            9)
                read -p "使用通配符证书？ (true/false): " NEW_VALUE
                update_config "WILDCARD" "$NEW_VALUE"
                ;;
            10)
                read -p "新 DNS 传播等待时间 (秒): " NEW_VALUE
                update_config "DNS_WAIT_TIME" "$NEW_VALUE"
                ;;
            *)
                log "ERROR" "无效的选项"
                exit 1
                ;;
        esac
        log "INFO" "配置已更新"
        ;;
    *)
        log "ERROR" "无效的选项"
        exit 1
        ;;
esac

log "INFO" "脚本执行完成"
