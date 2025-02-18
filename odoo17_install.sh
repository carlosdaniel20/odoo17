#!/bin/bash

# Variables de configuración
ODOO_VERSION="17.0"
ODOO_USER="odoo"
ODOO_HOME="/opt/$ODOO_USER"
ODOO_CONFIG="/etc/$ODOO_USER.conf"
ODOO_PORT="8077"  # Puerto en el que correrá Odoo
DOMAIN="tu-dominio.com"  # Cambia esto por tu dominio real

# Actualización del sistema
echo "🔄 Actualizando paquetes del sistema..."
sudo apt update && sudo apt upgrade -y

# Instalación de dependencias necesarias
echo "📦 Instalando paquetes requeridos..."
sudo apt install -y python3-pip python3-dev python3-venv \
    libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    build-essential libjpeg-dev libpq-dev libffi-dev \
    libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev \
    postgresql postgresql-contrib nginx certbot python3-certbot-nginx \
    wkhtmltopdf

# Crear usuario de Odoo
echo "👤 Creando usuario Odoo..."
sudo useradd -m -d $ODOO_HOME -U -r -s /bin/bash $ODOO_USER

# Configurar PostgreSQL
echo "💾 Configurando PostgreSQL..."
sudo -u postgres psql -c "CREATE USER $ODOO_USER WITH CREATEDB PASSWORD 'odoo';"

# Clonar Odoo desde GitHub
echo "📂 Clonando Odoo $ODOO_VERSION..."
sudo -u $ODOO_USER git clone --depth 1 --branch $ODOO_VERSION https://github.com/odoo/odoo.git $ODOO_HOME

# Crear entorno virtual y configurar dependencias de Python
echo "🐍 Creando entorno virtual..."
sudo -u $ODOO_USER python3 -m venv $ODOO_HOME/venv
source $ODOO_HOME/venv/bin/activate
pip install --upgrade pip setuptools wheel
pip install -r $ODOO_HOME/requirements.txt
deactivate

# Configurar el archivo de Odoo
echo "⚙ Configurando Odoo..."
cat <<EOF | sudo tee $ODOO_CONFIG
[options]
admin_passwd = admin
db_host = False
db_port = False
db_user = $ODOO_USER
db_password = odoo
addons_path = $ODOO_HOME/addons,$ODOO_HOME/odoo/addons
xmlrpc_port = $ODOO_PORT
EOF
sudo chown $ODOO_USER:$ODOO_USER $ODOO_CONFIG
sudo chmod 640 $ODOO_CONFIG

# Crear servicio systemd para Odoo
echo "🔧 Creando servicio de Odoo..."
cat <<EOF | sudo tee /etc/systemd/system/odoo.service
[Unit]
Description=Odoo ERP
After=network.target postgresql.service

[Service]
User=$ODOO_USER
Group=$ODOO_USER
ExecStart=$ODOO_HOME/venv/bin/python3 $ODOO_HOME/odoo-bin --config=$ODOO_CONFIG
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Recargar systemd y habilitar el servicio de Odoo
sudo systemctl daemon-reload
sudo systemctl enable --now odoo

# Configurar Nginx como proxy en el puerto 443
echo "🌐 Configurando Nginx como proxy HTTPS..."
cat <<EOF | sudo tee /etc/nginx/sites-available/odoo
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    access_log /var/log/nginx/odoo_access.log;
    error_log /var/log/nginx/odoo_error.log;

    location / {
        proxy_pass http://127.0.0.1:$ODOO_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_pass http://127.0.0.1:$ODOO_PORT;
    }
}
EOF

# Habilitar configuración en Nginx
sudo ln -s /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx

# Configurar SSL con Let's Encrypt
echo "🔐 Configurando SSL con Let's Encrypt..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

# Habilitar auto-renovación del certificado SSL
echo "🔄 Configurando renovación automática del SSL..."
echo "0 3 * * * root certbot renew --quiet" | sudo tee -a /etc/crontab > /dev/null

echo "✅ Instalación completada. Accede a Odoo en: https://$DOMAIN"
