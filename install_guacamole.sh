#!/bin/bash

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo systemctl start docker
sudo systemctl enable docker

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Add current user to docker group
sudo usermod -aG docker ${USER}
echo "Please log out and log back in for the changes to take effect."

# Install Guacamole
mkdir -p ~/docker-stack/guacamole/init
chmod -R 700 ~/docker-stack/guacamole/init
docker run --rm guacamole/guacamole:1.5.3 /opt/guacamole/bin/initdb.sh --postgresql ~/docker-stack/guacamole/init/initdb.sql

# Create Docker Compose file for Guacamole
cat << EOF > ~/docker-stack/guacamole/docker-compose.yml
version: '3.9'

networks:
  guacamole-net:
    driver: bridge
  haproxy-net:
    external: true

services:
  Guacd:
    container_name: guacamole-backend
    image: guacamole/guacd:1.5.3
    networks:
      - guacamole-net
    restart: always
    volumes:
      - ./drive:/drive:rw
      - ./record:/var/lib/guacamole/records:rw

  Postgres:
    container_name: guacamole-database
    environment:
      PGDATA: /var/lib/postgresql/data/guacamole
      POSTGRES_DB: guacamole-db
      POSTGRES_PASSWORD: 'YourStrongPassword'
      POSTGRES_USER: 'guacamole-user'
    image: postgres:15.0
    networks:
      - guacamole-net
    restart: always
    volumes:
      - ./init:/docker-entrypoint-initdb.d:ro
      - ./data:/var/lib/postgresql/data:rw

  guacamole:
    container_name: guacamole-frontend
    depends_on:
      - Guacd
      - Postgres
    environment:
      GUACD_HOSTNAME: Guacd
      POSTGRESQL_DATABASE: guacamole-db
      POSTGRESQL_HOSTNAME: Postgres
      POSTGRESQL_PASSWORD: 'YourStrongPassword'
      POSTGRESQL_USER: 'guacamole-user'
      POSTGRESQL_AUTO_CREATE_ACCOUNTS: 'true'
    image: guacamole/guacamole:1.5.3
    links:
      - Guacd
    networks:
      - guacamole-net
      - haproxy-net
    restart: always
    volumes:
      - ./drive:/drive:rw
      - ./record:/var/lib/guacamole/records:rw
EOF

# Create .env file for Guacamole credentials
cat << EOF > ~/docker-stack/guacamole/.env
POSTGRES_PASSWORD='YourStrongPassword'
POSTGRES_USER='guacamole-user'
EOF

# Install HAProxy
mkdir -p ~/docker-stack/haproxy
cat << EOF > ~/docker-stack/haproxy/docker-compose.yml
version: '3.9'

services:
  haproxy:
    container_name: haproxy
    image: haproxytech/haproxy-alpine:2.4
    ports:
      - "80:80"
      - "443:443"
      - "8404:8404"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - haproxy-net
    restart: always
    environment:
      ENDPOINT: '$(curl -s ifconfig.me)'

  reverse-proxy-https-helper:
    image: alpine
    command: sh -c "echo 'No certificate generation needed for IP address'"
    networks:
      - haproxy-net

networks:
  haproxy-net:
    driver: bridge
EOF

# Create HAProxy configuration file
cat << EOF > ~/docker-stack/haproxy/haproxy.cfg
global
  stats socket /var/run/api.sock user haproxy group haproxy mode 660 level admin
  log stdout format raw local0 info
  maxconn 50000

resolvers docker-resolver
  nameserver dns 127.0.0.11:53

defaults
  mode http
  timeout client 10s
  timeout connect 5s
  timeout server 10s
  timeout http-request 10s
  default-server init-addr none
  log global

frontend myfrontend
  mode http
  bind :80
  bind :443 ssl crt /etc/ssl/certs/haproxy-ssl.pem
  http-request redirect scheme https code 301 unless { ssl_fc }
  use_backend %[req.hdr(host),lower]

backend "your-fqdn"
  server guacamole guacamole:8080 check inter 10s resolvers docker-resolver
EOF

# Start containers
cd ~/docker-stack/haproxy
docker-compose up -d

cd ~/docker-stack/guacamole
docker-compose up -d

echo "Guacamole and HAProxy have been deployed successfully."

