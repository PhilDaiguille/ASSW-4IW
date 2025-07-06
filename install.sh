#!/bin/bash

set -e

DOMAIN_DOLIBARR="dolibarr.4iw.lab"
DOMAIN_GLPI="glpi.4iw.lab"
APACHE_DIR="/etc/apache2"
SITES_DIR="$APACHE_DIR/sites-available"
WWW_DIR="/var/www"
CERTS_DIR="/home/webadm/ASSW-4IW/certs"
ARCHIVES_DIR="/home/webadm/ASSW-4IW/archives"
AUTH_DIR="/home/webadm/ASSW-4IW/auth"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Ce script doit être exécuté en tant que root"
        exit 1
    fi
}

create_directories() {
    log "Création des répertoires nécessaires..."

    mkdir -p "$CERTS_DIR/ca"
    mkdir -p "$CERTS_DIR/server"
    mkdir -p "$CERTS_DIR/clients"

    mkdir -p "$AUTH_DIR"

    mkdir -p "$ARCHIVES_DIR"

    log "Répertoires créés avec succès"
}

install_dependencies() {
    log "Installation des dépendances..."
    apt update
    apt install -y apache2 mariadb-server php php-gd php-zip php-curl php-xml php-mysql php-mbstring php-json php-ldap php-imap php-intl php-soap php-cli unzip openssl apache2-utils

    sleep 3

    export PATH="/usr/sbin:$PATH"
    source /etc/environment 2>/dev/null || true

    if [[ ! -f "/usr/sbin/a2enmod" ]]; then
        error "Apache n'est pas correctement installé - fichier a2enmod introuvable"
        log "Tentative de réinstallation d'Apache..."
        apt install --reinstall -y apache2
        sleep 2
        if [[ ! -f "/usr/sbin/a2enmod" ]]; then
            error "Impossible d'installer Apache correctement"
            exit 1
        fi
    fi

    /usr/sbin/a2enmod ssl
    /usr/sbin/a2enmod rewrite
    /usr/sbin/a2enmod headers

    systemctl enable apache2
    systemctl enable mariadb
    systemctl start apache2
}

setup_database() {
    log "Configuration de la base de données..."

    systemctl start mariadb

    log "Sécurisation de MariaDB..."

    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';" 2>/dev/null || \
    mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('root');" 2>/dev/null || \
    mysql -e "UPDATE mysql.user SET authentication_string = PASSWORD('root') WHERE User = 'root';" 2>/dev/null || \
    log "Mot de passe root déjà configuré ou méthode alternative utilisée"

    mysql -u root -proot -e "DELETE FROM mysql.user WHERE User = '';" 2>/dev/null || true

    mysql -u root -proot -e "DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true

    mysql -u root -proot -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql -u root -proot -e "DELETE FROM mysql.db WHERE Db = 'test' OR Db = 'test\\_%';" 2>/dev/null || true

    mysql -u root -proot -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    log "Création des bases de données pour Dolibarr et GLPI..."

    mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS dolibarr CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -u root -proot -e "CREATE USER IF NOT EXISTS 'dolibarr'@'localhost' IDENTIFIED BY 'dolibarr123';"
    mysql -u root -proot -e "GRANT ALL PRIVILEGES ON dolibarr.* TO 'dolibarr'@'localhost';"

    mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -u root -proot -e "CREATE USER IF NOT EXISTS 'glpi'@'localhost' IDENTIFIED BY 'glpi123';"
    mysql -u root -proot -e "GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'localhost';"

    mysql -u root -proot -e "FLUSH PRIVILEGES;"

    log "Bases de données configurées avec succès"
}

install_dolibarr() {
    log "Installation de Dolibarr..."

    log "Vérification de l'archive locale : $ARCHIVES_DIR/dolibarr-19.0.3.tgz"
    ls -la "$ARCHIVES_DIR/" || log "Erreur : impossible de lister le dossier archives"

    if [[ -f "$ARCHIVES_DIR/dolibarr-19.0.3.tgz" ]]; then
        log "Utilisation de l'archive locale Dolibarr"
        cd /tmp
        cp "$ARCHIVES_DIR/dolibarr-19.0.3.tgz" .
        tar -xzf dolibarr-19.0.3.tgz

        log "Contenu extrait dans /tmp :"
        ls -la /tmp/ | grep dolibarr || ls -la /tmp/

        EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "*dolibarr*" | head -1)
        if [[ -z "$EXTRACTED_DIR" ]]; then
            error "Impossible de trouver le dossier Dolibarr extrait"
            exit 1
        fi
        log "Dossier trouvé : $EXTRACTED_DIR"
    else
        log "Téléchargement de Dolibarr..."
        cd /tmp
        wget -O dolibarr.tgz "https://github.com/Dolibarr/dolibarr/archive/refs/tags/19.0.3.tar.gz"
        tar -xzf dolibarr.tgz
        EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "*dolibarr*" | head -1)
    fi

    rm -rf "$WWW_DIR/dolibarr"
    mv "$EXTRACTED_DIR" "$WWW_DIR/dolibarr"

    chown -R www-data:www-data "$WWW_DIR/dolibarr"
    chmod -R 755 "$WWW_DIR/dolibarr"

    mkdir -p "$WWW_DIR/dolibarr/htdocs/conf"
    chown www-data:www-data "$WWW_DIR/dolibarr/htdocs/conf"
    chmod 755 "$WWW_DIR/dolibarr/htdocs/conf"
}

install_glpi() {
    log "Installation de GLPI..."

    log "Vérification de l'archive locale : $ARCHIVES_DIR/glpi-10.0.18.tgz"
    ls -la "$ARCHIVES_DIR/" || log "Erreur : impossible de lister le dossier archives"

    if [[ -f "$ARCHIVES_DIR/glpi-10.0.18.tgz" ]]; then
        log "Utilisation de l'archive locale GLPI"
        cd /tmp
        cp "$ARCHIVES_DIR/glpi-10.0.18.tgz" .
        tar -xzf glpi-10.0.18.tgz

        log "Contenu extrait dans /tmp :"
        ls -la /tmp/ | grep glpi || ls -la /tmp/

        EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "*glpi*" | head -1)
        if [[ -z "$EXTRACTED_DIR" ]]; then
            error "Impossible de trouver le dossier GLPI extrait"
            exit 1
        fi
        log "Dossier trouvé : $EXTRACTED_DIR"
    else
        log "Téléchargement de GLPI..."
        cd /tmp
        wget -O glpi.tgz "https://github.com/glpi-project/glpi/releases/download/10.0.18/glpi-10.0.18.tgz"
        tar -xzf glpi.tgz
        EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "*glpi*" | head -1)
    fi

    rm -rf "$WWW_DIR/glpi"
    mv "$EXTRACTED_DIR" "$WWW_DIR/glpi"

    chown -R www-data:www-data "$WWW_DIR/glpi"
    chmod -R 755 "$WWW_DIR/glpi"
}

create_ca() {
    log "Création de l'autorité de certification..."

    cd "$CERTS_DIR/ca"

    openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:4096

    openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 -out ca.crt -subj "/C=FR/ST=IDF/L=Paris/O=4IW Lab/OU=CA/CN=4IW Root CA"

    log "CA créée avec succès"
}

create_server_certificates() {
    log "Génération des certificats serveur..."

    cd "$CERTS_DIR/server"

    openssl genpkey -algorithm RSA -out dolibarr.key -pkeyopt rsa_keygen_bits:2048
    openssl req -new -key dolibarr.key -out dolibarr.csr -subj "/C=FR/ST=IDF/L=Paris/O=4IW Lab/OU=Server/CN=$DOMAIN_DOLIBARR"
    openssl x509 -req -in dolibarr.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out dolibarr.crt -days 365 -sha256

    openssl genpkey -algorithm RSA -out glpi.key -pkeyopt rsa_keygen_bits:2048
    openssl req -new -key glpi.key -out glpi.csr -subj "/C=FR/ST=IDF/L=Paris/O=4IW Lab/OU=Server/CN=$DOMAIN_GLPI"
    openssl x509 -req -in glpi.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out glpi.crt -days 365 -sha256

    log "Certificats serveur créés avec succès"
}

create_client_certificates() {
    log "Génération des certificats clients..."

    cd "$CERTS_DIR/clients"

    openssl genpkey -algorithm RSA -out client.key -pkeyopt rsa_keygen_bits:2048
    openssl req -new -key client.key -out client.csr -subj "/C=FR/ST=IDF/L=Paris/O=4IW Lab/OU=Client/CN=4IW Client"
    openssl x509 -req -in client.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out client.crt -days 365 -sha256

    openssl pkcs12 -export -in client.crt -inkey client.key -out client.p12 -password pass:client123

    log "Certificats clients créés avec succès"
}

configure_apache() {
    log "Configuration d'Apache..."

    cat > "$SITES_DIR/dolibarr.conf" << EOF
<VirtualHost *:80>
    ServerName $DOMAIN_DOLIBARR
    DocumentRoot $WWW_DIR/dolibarr/htdocs

    # Redirection vers HTTPS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN_DOLIBARR
    DocumentRoot $WWW_DIR/dolibarr/htdocs

    # Configuration SSL
    SSLEngine on
    SSLCertificateFile $CERTS_DIR/server/dolibarr.crt
    SSLCertificateKeyFile $CERTS_DIR/server/dolibarr.key
    SSLCACertificateFile $CERTS_DIR/ca/ca.crt

    # Configuration PHP
    <Directory $WWW_DIR/dolibarr/htdocs>
        AllowOverride All
        Require all granted
    </Directory>

    # Logs
    ErrorLog \${APACHE_LOG_DIR}/dolibarr_error.log
    CustomLog \${APACHE_LOG_DIR}/dolibarr_access.log combined
</VirtualHost>
EOF

    cat > "$SITES_DIR/glpi.conf" << EOF
<VirtualHost *:80>
    ServerName $DOMAIN_GLPI
    DocumentRoot $WWW_DIR/glpi/public

    # Redirection vers HTTPS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN_GLPI
    DocumentRoot $WWW_DIR/glpi/public

    # Configuration SSL
    SSLEngine on
    SSLCertificateFile $CERTS_DIR/server/glpi.crt
    SSLCertificateKeyFile $CERTS_DIR/server/glpi.key
    SSLCACertificateFile $CERTS_DIR/ca/ca.crt

    # Configuration PHP
    <Directory $WWW_DIR/glpi/public>
        AllowOverride All
        Require all granted
    </Directory>

    # Logs
    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF

    /usr/sbin/a2ensite dolibarr.conf
    /usr/sbin/a2ensite glpi.conf
}

configure_basic_auth() {
    log "Configuration de l'authentification basique..."

    if ! command -v htpasswd &> /dev/null; then
        error "htpasswd n'est pas disponible. Installation d'apache2-utils..."
        apt install -y apache2-utils
    fi

    htpasswd -cb "$AUTH_DIR/.htpasswd" admin admin123

    cat > "$SITES_DIR/000-default.conf" << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    # Authentification basique
    <Directory /var/www/html>
        AuthType Basic
        AuthName "Accès Restreint - 4IW Lab"
        AuthBasicProvider file
        AuthUserFile $AUTH_DIR/.htpasswd
        Require valid-user
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/default_error.log
    CustomLog \${APACHE_LOG_DIR}/default_access.log combined
</VirtualHost>
EOF
}

main() {
    log "Démarrage de l'installation automatisée..."

    check_root
    create_directories
    install_dependencies
    setup_database
    install_dolibarr
    install_glpi
    create_ca
    create_server_certificates
    create_client_certificates
    configure_apache
    configure_basic_auth

    systemctl restart apache2

    log "Installation terminée avec succès !"
    log ""
    log "Accès aux applications :"
    log "- Dolibarr : https://$DOMAIN_DOLIBARR"
    log "- GLPI : https://$DOMAIN_GLPI"
    log ""
    log "Certificat CA : $CERTS_DIR/ca/ca.crt"
    log "Certificat client : $CERTS_DIR/clients/client.p12 (mot de passe: client123)"
    log ""
    log "Authentification page par défaut : admin/admin123"
    log ""
    log "N'oubliez pas d'ajouter les domaines dans votre /etc/hosts :"
    log "127.0.0.1 $DOMAIN_DOLIBARR"
    log "127.0.0.1 $DOMAIN_GLPI"
}

main "$@"