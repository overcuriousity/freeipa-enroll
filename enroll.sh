#!/bin/bash

# Exit on error
set -e

# Check if hostname parameter is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <hostname>"
    echo "Example: $0 siem"
    exit 1
fi

HOSTNAME="$1"
DOMAIN="mikoshi.cc"
FQDN="${HOSTNAME}.${DOMAIN}"

echo "==============================================="
echo "Starting setup for $FQDN"
echo "==============================================="

# Step 1: Verify IP address
echo "Current IP configuration:"
ip addr show
echo ""
read -p "Is the IP address correct? (y/n): " ip_correct
if [[ "$ip_correct" != "y" && "$ip_correct" != "Y" ]]; then
    echo "Please configure the correct IP address before continuing."
    exit 1
fi

# Step 2: Initial package installation
echo "==============================================="
echo "Installing initial packages..."
echo "==============================================="
apt update && apt upgrade -y && apt install sudo lsb-release -y

# Step 3: Install FreeIPA client and join domain
echo "==============================================="
echo "Installing FreeIPA client and joining domain..."
echo "==============================================="
sudo apt update && sudo apt upgrade -y && sudo apt install -y sudo freeipa-client
echo "You will be prompted for confirmation and admin password:"
sudo ipa-client-install --no-ntp --mkhomedir --enable-dns-updates --all-ip-addresses --ssh-trust-dns --principal=admin

# Step 4: Request certificate from FreeIPA
echo "==============================================="
echo "Requesting certificate from FreeIPA for $FQDN..."
echo "==============================================="
sudo ipa-getcert request -f /etc/ssl/fullchain.pem -k /etc/ssl/privkey.pem -N CN=$FQDN -D $FQDN -K HTTP/$FQDN

# Step 5: Run script-based enrollment
echo "==============================================="
echo "Running FreeIPA service account enrollment for $HOSTNAME..."
echo "==============================================="
kinit admin
cat > /tmp/freeipa-enrollment.sh << 'EOFSCRIPT'
#!/bin/bash
# Check if hostname parameter is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <hostname>"
    echo "Example: $0 siem"
    exit 1
fi
HOSTNAME="$1"
DOMAIN="mikoshi.cc"
FQDN="${HOSTNAME}.${DOMAIN}"
USERNAME="svc-${HOSTNAME}"
FIRSTNAME="SERVICE"
LASTNAME="${HOSTNAME^^}" # Convert to uppercase
echo "Creating service account and configurations for ${FQDN}"
# Create service user
echo "Creating user ${USERNAME}..."
ipa user-add "${USERNAME}" \
    --first="${FIRSTNAME}" \
    --last="${LASTNAME}" \
    --password
# Create HBAC rule
echo "Creating HBAC rule allow-${HOSTNAME}-access..."
ipa hbacrule-add "allow-${HOSTNAME}-access"
# Add user to HBAC rule
echo "Adding user to HBAC rule..."
ipa hbacrule-add-user "allow-${HOSTNAME}-access" --users="${USERNAME}"
# Add host to HBAC rule
echo "Adding host to HBAC rule..."
ipa hbacrule-add-host "allow-${HOSTNAME}-access" --hosts="${FQDN}"
# Add HBAC services
echo "Adding HBAC services..."
ipa hbacrule-add-service "allow-${HOSTNAME}-access" --hbacsvcgroups="server-admin-access"
# Add host to managed-webservers group
echo "Adding host to managed-webservers group..."
ipa hostgroup-add-member managed-webservers --hosts="${FQDN}"
# Add sudo rule to user
echo "Adding sudo rule to user..."
ipa sudorule-add-user server-admin-sudo --users="${USERNAME}"
echo "Configuration completed successfully!"
echo "Please remember to change the password for ${USERNAME}"
EOFSCRIPT

chmod +x /tmp/freeipa-enrollment.sh
/tmp/freeipa-enrollment.sh "$HOSTNAME"
rm /tmp/freeipa-enrollment.sh

# Step 6: Install nginx
echo "==============================================="
echo "Installing nginx..."
echo "==============================================="
sudo apt install -y nginx

# Step 7: Configure nginx
echo "==============================================="
echo "Configuring nginx for $FQDN..."
echo "==============================================="
read -p "Enter the port for proxying to localhost (e.g., 5380): " proxy_port

# Create nginx configuration
cat > /etc/nginx/sites-available/$HOSTNAME << EOF
server {
  listen 443 ssl http2;
  server_name $FQDN;
  # SSL configuration
  ssl_certificate /etc/ssl/fullchain.pem;
  ssl_certificate_key /etc/ssl/privkey.pem;
  
  # Modern SSL configuration
  ssl_protocols TLSv1.3;
  ssl_prefer_server_ciphers off;
  # SSL session settings
  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:50m;
  ssl_session_tickets off;
  # Basic security headers
  add_header X-Frame-Options SAMEORIGIN;
  add_header X-Content-Type-Options nosniff;
  add_header X-XSS-Protection "1; mode=block";
  location / {
      proxy_pass http://127.0.0.1:$proxy_port;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      
      # WebSocket timeout settings
      proxy_read_timeout 86400;
      proxy_send_timeout 86400;
  }
}
server {
    listen 80;
    server_name $FQDN;
    # Redirect all HTTP traffic to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF

# Enable the site
ln -sf /etc/nginx/sites-available/$HOSTNAME /etc/nginx/sites-enabled/

# Test and reload nginx
echo "Testing nginx configuration..."
nginx -t
if [ $? -eq 0 ]; then
    echo "Reloading nginx..."
    systemctl reload nginx
else
    echo "Nginx configuration test failed. Please check the configuration."
    exit 1
fi

echo "==============================================="
echo "Setup completed successfully for $FQDN"
echo "==============================================="
echo "Web service configured on port $proxy_port"
echo "Remember to configure your application to listen on port $proxy_port"
echo "Nginx is configured to proxy requests to this port"
echo "==============================================="
