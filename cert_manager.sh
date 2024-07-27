#!/bin/bash

# Determine the base directory dynamically
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define file paths
CONFIG_FILE="$BASE_DIR/config.sh"
AUTH_HOOK_SCRIPT="$BASE_DIR/auth-hook-script.sh"
RENEW_DEPLOY_SCRIPT="$BASE_DIR/renew_and_deploy.sh"
MAIN_SCRIPT="$BASE_DIR/cert_main.sh"

# Create necessary directories and set permissions
mkdir -p $BASE_DIR
chmod 700 $BASE_DIR

# Check and install required packages
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
        echo "无法安装 $1. 请手动安装."
        exit 1
    fi
}

check_and_install_dependencies() {
    for pkg in certbot curl jq; do
        if ! command -v $pkg &> /dev/null; then
            echo "$pkg 未安装. 正在安装..."
            install_package $pkg
        fi
    done
}

# Run the function to check and install dependencies
check_and_install_dependencies

# Prompt user for Cloudflare API key and save to config file
if [ ! -f $CONFIG_FILE ]; then
    echo "请输入你的 Cloudflare API 密钥："
    read -s CF_API_KEY

    echo "请输入你的 Cloudflare API 电子邮件："
    read CF_API_EMAIL

    echo "请输入你的域名 (例如 example.com)："
    read DOMAIN

    echo "请输入保存证书的目录 (例如 /var/www/html/downloads/cert/ocserv)："
    read CERT_DIR

    echo "请输入远程节点服务器 (逗号分隔，例如 node1.example.com,node2.example.com)："
    read NODE_SERVERS

    echo "请输入远程服务器上证书文件的文件名 (例如 server-cert.pem)："
    read REMOTE_CERT_FILE

    echo "请输入远程服务器上私钥文件的文件名 (例如 server-key.pem)："
    read REMOTE_KEY_FILE

    echo "请输入远程服务器上保存证书的目录 (例如 /root/cert/ocserv)："
    read REMOTE_CERT_DIR

    cat << EOF > $CONFIG_FILE
# config.sh

# Domain for which to obtain the wildcard certificate
DOMAIN="$DOMAIN"

# Cloudflare API details
CF_API_EMAIL="$CF_API_EMAIL"
CF_API_KEY="$CF_API_KEY"

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
        -H "X-Auth-Key: \$CF_API_KEY" \\
        -H "Content-Type: application/json" | jq -r '.result[0].id')

RECORD_NAME="_acme-challenge.\$DOMAIN"

# Debug output
echo "DOMAIN: \$DOMAIN"
echo "TOKEN_VALUE: \$TOKEN_VALUE"
echo "CF_ZONE_ID: \$CF_ZONE_ID"
echo "RECORD_NAME: \$RECORD_NAME"

# Find existing record if it exists
RECORD_ID=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/\$CF_ZONE_ID/dns_records?type=TXT&name=\$RECORD_NAME" \\
    -H "X-Auth-Email: \$CF_API_EMAIL" \\
    -H "X-Auth-Key: \$CF_API_KEY" \\
    -H "Content-Type: application/json" | jq -r '.result[0].id')

echo "RECORD_ID: \$RECORD_ID"

if [ "\$RECORD_ID" != "null" ] && [ -n "\$RECORD_ID" ]; then
    # Update existing record
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/\$CF_ZONE_ID/dns_records/\$RECORD_ID" \\
        -H "X-Auth-Email: \$CF_API_EMAIL" \\
        -H "X-Auth-Key: \$CF_API_KEY" \\
        -H "Content-Type: application/json" \\
        --data '{"type":"TXT","name":"'$RECORD_NAME'","content":"'$TOKEN_VALUE'","ttl":120}'
else
    # Create new record
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/\$CF_ZONE_ID/dns_records" \\
        -H "X-Auth-Email: \$CF_API_EMAIL" \\
        -H "X-Auth-Key: \$CF_API_KEY" \\
        -H "Content-Type: application/json" \\
        --data '{"type":"TXT","name":"'$RECORD_NAME'","content":"'$TOKEN_VALUE'","ttl":120}'
fi

# Sleep for a short time to allow DNS propagation
sleep 30
EOF
chmod +x $AUTH_HOOK_SCRIPT

# Create the renewal and deployment script
cat << EOF > $RENEW_DEPLOY_SCRIPT
#!/bin/bash
source $CONFIG_FILE

# Obtain the wildcard certificate using certbot and dns-01 challenge
certbot certonly --manual --preferred-challenges dns-01 --manual-auth-hook $AUTH_HOOK_SCRIPT --manual-cleanup-hook "echo 'Cleanup not needed for Cloudflare'" -d "*.$DOMAIN" --agree-tos -m "\$CF_API_EMAIL" --non-interactive --expand

# Move the certificates to the desired location and rename them
CERT_PATH="/etc/letsencrypt/live/\$DOMAIN"
cp "\$CERT_PATH/fullchain.pem" "\$CERT_DIR/\$REMOTE_CERT_FILE"
cp "\$CERT_PATH/privkey.pem" "\$CERT_DIR/\$REMOTE_KEY_FILE"

echo "证书和密钥已保存到 \$CERT_DIR"

# Copy the certificates to each remote machine
IFS=',' read -ra NODES <<< "\$NODE_SERVERS"
for remote in "\${NODES[@]}"; do
    scp -o StrictHostKeyChecking=no "\$CERT_DIR/\$REMOTE_CERT_FILE" "\$CERT_DIR/\$REMOTE_KEY_FILE" root@\$remote:\$REMOTE_CERT_DIR/
done

echo "证书已复制到远程服务器."
EOF
chmod +x $RENEW_DEPLOY_SCRIPT

# Create the main script
cat << EOF > $MAIN_SCRIPT
#!/bin/bash
source $CONFIG_FILE

# Function to update the domain in the certbot renewal configuration file
update_certbot_renewal_conf() {
    local NEW_DOMAIN=\$1
    local CONF_FILE="/etc/letsencrypt/renewal/\${NEW_DOMAIN}.conf"
    
    if [ -f "\$CONF_FILE" ]; then
        sed -i "s/^domains = .*/domains = *.\$NEW_DOMAIN/" "\$CONF_FILE"
    fi
}

# Function to check if the certificate is due for renewal
is_certificate_due_for_renewal() {
    local DOMAIN=\$1
    local EXPIRY_DATE=\$(certbot certificates --domain "\$DOMAIN" | grep "Expiry Date" | awk -F ': ' '{print \$2}')
    
    if [ -z "\$EXPIRY_DATE" ]; then
        echo "未找到 \$DOMAIN 的现有证书。"
        return 0  # No existing certificate, so it needs to be obtained
    fi
    
    local EXPIRY_TIMESTAMP=\$(date -d "\$EXPIRY_DATE" +%s)
    local CURRENT_TIMESTAMP=\$(date +%s)
    local THIRTY_DAYS_IN_SECONDS=\$((30 * 24 * 60 * 60))
    
    if [ \$((EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP)) -le \$THIRTY_DAYS_IN_SECONDS ]; then
        echo "证书 \$DOMAIN 需要续订。"
        return 0  # Certificate is due for renewal
    else
        echo "证书 \$DOMAIN 不需要续订。"
        return 1  # Certificate is not due for renewal
    fi
}

# Check if the certificate is due for renewal
if ! is_certificate_due_for_renewal "\$DOMAIN"; then
    echo "跳过证书续订。"
    exit 0
fi

# Get the Zone ID for the domain
CF_ZONE_ID=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=\$DOMAIN" \\
        -H "X-Auth-Email: \$CF_API_EMAIL" \\
        -H "X-Auth-Key: \$CF_API_KEY" \\
        -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "\$CF_ZONE_ID" == "null" ] || [ -z "\$CF_ZONE_ID" ]; then
    echo "无法检索区域 ID。请检查你的 Cloudflare 凭据和域名。"
    exit 1
fi

echo "使用 CF_ZONE_ID: \$CF_ZONE_ID"

# Ensure the directory exists
mkdir -p "\$CERT_DIR"

# Obtain the wildcard certificate using certbot and dns-01 challenge
certbot certonly --manual --preferred-challenges dns-01 --manual-auth-hook "$AUTH_HOOK_SCRIPT" --manual-cleanup-hook "echo 'Cleanup not needed for Cloudflare'" -d "*.\$DOMAIN" --agree-tos -m "\$CF_API_EMAIL" --non-interactive --expand

# Move the certificates to the desired location and rename them
CERT_PATH="/etc/letsencrypt/live/\$DOMAIN"
cp "\$CERT_PATH/fullchain.pem" "\$CERT_DIR/\$REMOTE_CERT_FILE"
cp "\$CERT_PATH/privkey.pem" "\$CERT_DIR/\$REMOTE_KEY_FILE"

echo "证书和密钥已保存到 \$CERT_DIR"

# Copy the certificates to each remote machine
IFS=',' read -ra NODES <<< "\$NODE_SERVERS"
for remote in "\${NODES[@]}"; do
    scp -o StrictHostKeyChecking=no "\$CERT_DIR/\$REMOTE_CERT_FILE" "\$CERT_DIR/\$REMOTE_KEY_FILE" root@\$remote:\$REMOTE_CERT_DIR/
done

echo "证书已复制到远程服务器."

# Update certbot renewal configuration file
update_certbot_renewal_conf "\$DOMAIN"

# Add a cron job for automatic renewal
CRON_JOB="0 0 * * * /usr/bin/certbot renew --manual --preferred-challenges dns-01 --manual-auth-hook $AUTH_HOOK_SCRIPT --manual-cleanup-hook \\"echo 'Cleanup not needed for Cloudflare'\\" --deploy-hook $RENEW_DEPLOY_SCRIPT"

# Check if the cron job already exists
(crontab -l 2>/dev/null | grep -F "\$CRON_JOB") || (crontab -l 2>/dev/null; echo "\$CRON_JOB") | crontab -

echo "自动续订 cron 任务已添加。"
EOF
chmod +x $MAIN_SCRIPT

# Prompt user for action
echo "请选择一个操作："
echo "1. 发行/续订证书"
echo "2. 列出证书"
echo "3. 删除证书"
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
        ;;
    *)
        echo "无效的选项。退出。"
        ;;
esac
