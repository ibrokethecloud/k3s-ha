#!/bin/bash
NODE1=${1:?"Specify primary node ip"}
NODE2=${2:?"Specify secondary node ip"}
DEFAULT_IF=$(route | grep '^default' | grep -o '[^ ]*$')
VIRTUAL_IP=${3:?"Specify virtual ip"}
ROLE=${4:?"Specify a role, valid options are MASTER/BACKUP"}

# default credentials 
POSTGRESQL_PASSWORD="secretpass"
REPMGR_PASSWORD="repmgrpass"

# container runs as user 1001:1001 so persistent store needs to be preconfigured
mkdir -p /var/lib/rancher/postgres
chown 1001:1001 /var/lib/rancher/postgres

if [ ${ROLE} = "MASTER" ]; then
echo "booting postgres master"
docker run --detach --name pg-0 \
  --publish 5432:5432 \
  --add-host pg-0:${NODE1} \
  --add-host pg-1:${NODE2} \
  --env REPMGR_PARTNER_NODES="pg-0,pg-1" \
  --env REPMGR_NODE_NAME=pg-0 \
  --env REPMGR_NODE_NETWORK_NAME=pg-0 \
  --env REPMGR_PRIMARY_HOST=pg-0 \
  --env REPMGR_PASSWORD=$REPMGR_PASSWORD \
  --env POSTGRESQL_PASSWORD=$POSTGRESQL_PASSWORD \
  --volume /var/lib/rancher/postgres:/bitnami/postgresql/data \
  --restart always \
  bitnami/postgresql-repmgr:latest
else 
echo "booting postgres slave"
docker run --detach --name pg-1 \
  --publish 5432:5432 \
  --add-host pg-0:${NODE1} \
  --add-host pg-1:${NODE2} \
  --env REPMGR_PARTNER_NODES="pg-0,pg-1" \
  --env REPMGR_NODE_NAME=pg-1 \
  --env REPMGR_NODE_NETWORK_NAME=pg-1 \
  --env REPMGR_PRIMARY_HOST=pg-0 \
  --env REPMGR_PASSWORD=$REPMGR_PASSWORD \
  --env POSTGRESQL_PASSWORD=$POSTGRESQL_PASSWORD \
  --restart always \
  --volume /var/lib/rancher/postgres:/bitnami/postgresql/data \
  bitnami/postgresql-repmgr:latest
fi  


echo "firing up keepalived"
docker run \
  --cap-add=NET_ADMIN \
  --cap-add=NET_BROADCAST \
  --cap-add=NET_RAW \
  --net=host \
  --env KEEPALIVED_INTERFACE=$DEFAULT_IF \
  --env KEEPALIVED_UNICAST_PEERS="#PYTHON2BASH:[$NODE1, $NODE2]" \
  --env KEEPALIVED_STATE=$ROLE \
  --env KEEPALIVED_VIRTUAL_IPS=$VIRTUAL_IP \
  --name vip \
  --restart always \
  -d osixia/keepalived:2.0.20

echo "delaying k3s boot for a min to make sure db is up.."
sleep 60

echo "booting k3s with external db"
curl -sfL https://get.k3s.io | sh -s - server --tls-san $VIRTUAL_IP \
  --datastore-endpoint="postgres://postgres:secretpass@$VIRTUAL_IP:5432/kine?sslmode=disable" 
