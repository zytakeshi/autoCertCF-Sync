# autoCertCF-Sync
以API申请wildcard通配符证书并同步到节点服务器


### 使用指南和注意事项

#### 简介

`cert_manager.sh` 是一个脚本，用于在 Linux 系统上管理 SSL/TLS 证书。它可以自动获取和续订通配符证书，并将它们分发到远程服务器上。脚本会检查并安装所需的依赖项，并使用 Cloudflare 的 DNS 挑战来验证域名所有权。

#### 功能

1. **发行/续订证书**
2. **列出现有证书**
3. **删除证书**

#### 先决条件

- 您必须有一个可以访问的 Cloudflare 账户，并获得 API 密钥和电子邮件地址。
- 确保目标服务器可以通过 SSH 无密码访问。
- 脚本会自动安装所需的依赖项（`certbot`, `curl`, `jq`）。

#### 使用步骤

1. **下载并配置脚本**

    ```bash
    wget https://github.com/your-repo/cert_manager.sh
    chmod +x cert_manager.sh
    ```

2. **配置 SSH 密钥**

    确保您已经在本地机器和远程节点服务器之间配置了 SSH 密钥。以下是配置方法：

    **生成 SSH 密钥：**

    ```bash
    ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
    ```

    **将公钥复制到远程服务器：**

    ```bash
    ssh-copy-id root@remote_server
    ```

    如果 `ssh-copy-id` 不可用，可以手动复制公钥：

    ```bash
    cat ~/.ssh/id_rsa.pub | ssh root@remote_server 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
    ```

3. **运行脚本**

    ```bash
    ./cert_manager.sh
    ```

4. **选择操作**

    脚本启动后，会提示您选择操作：

    ```bash
    请选择一个操作：
    1. 发行/续订证书
    2. 列出证书
    3. 删除证书
    ```

    根据需要输入相应的数字进行操作。

#### 配置说明

**首次运行脚本时，会提示输入以下信息：**

1. **Cloudflare API 密钥：** 这将用于访问 Cloudflare API。
2. **Cloudflare API 电子邮件：** 这是与您的 Cloudflare 帐户关联的电子邮件地址。
3. **域名：** 您希望为其获取通配符证书的域名。
4. **保存证书的本地目录：** 证书将保存到本地机器的目录。
5. **远程节点服务器：** 逗号分隔的远程服务器列表。
6. **远程服务器上证书文件的文件名：** 将证书复制到远程服务器时使用的文件名。
7. **远程服务器上私钥文件的文件名：** 将私钥复制到远程服务器时使用的文件名。
8. **远程服务器上保存证书的目录：** 证书和私钥将保存到远程服务器的目录。

#### 示例配置

1. **Cloudflare API 密钥：** 输入您的 Cloudflare API 密钥。
2. **Cloudflare API 电子邮件：** 输入您的 Cloudflare API 电子邮件。
3. **域名：** `example.com`
4. **保存证书的本地目录：** `/var/www/html/downloads/cert/ocserv`
5. **远程节点服务器：** `node1.example.com,node2.example.com`
6. **远程服务器上证书文件的文件名：** `server-cert.pem`
7. **远程服务器上私钥文件的文件名：** `server-key.pem`
8. **远程服务器上保存证书的目录：** `/root/cert/ocserv`

#### 注意事项

- 确保本地和远程服务器之间的 SSH 无密码登录已正确配置。
- 如果需要手动安装依赖项，请使用以下命令：

    **Debian/Ubuntu:**

    ```bash
    sudo apt-get update
    sudo apt-get install -y certbot curl jq
    ```

    **CentOS/RHEL:**

    ```bash
    sudo yum install -y epel-release
    sudo yum install -y certbot curl jq
    ```

    **Fedora:**

    ```bash
    sudo dnf install -y certbot curl jq
    ```

    **openSUSE:**

    ```bash
    sudo zypper install -y certbot curl jq
    ```

- 确保 Cloudflare API 密钥和电子邮件正确无误，否则无法获取证书。
- 证书和私钥将保存在本地目录，并自动复制到配置的远程服务器上。

通过以上步骤，您可以轻松地管理和分发 SSL/TLS 证书。如果有任何问题，请参考脚本输出的错误信息进行排查。
