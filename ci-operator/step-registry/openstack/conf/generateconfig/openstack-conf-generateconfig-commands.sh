#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
OPENSTACK_COMPUTE_FLAVOR="${OPENSTACK_COMPUTE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")}"
ZONES="${ZONES:-$(<"${SHARED_DIR}/ZONES")}"
ZONES_COUNT="${ZONES_COUNT:-0}"

API_IP=$(<"${SHARED_DIR}"/API_IP)
INGRESS_IP=$(<"${SHARED_DIR}"/INGRESS_IP)

PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}"/pull-secret)
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)

CONFIG="${SHARED_DIR}/install-config.yaml"

case "$CONFIG_TYPE" in
  minimal|byon)
    ;;
  *)
    echo "No valid install config type specified. Please check CONFIG_TYPE"
    exit 1
    ;;
esac

mapfile -t ZONES < <(printf ${ZONES}) >/dev/null
MAX_ZONES_COUNT=${#ZONES[@]}

if [[ ${ZONES_COUNT} -gt ${MAX_ZONES_COUNT} ]]; then
  echo "Too many zones were requested: ${ZONES_COUNT}; only ${MAX_ZONES_COUNT} are available: ${ZONES[*]}"
  exit 1
fi

if [[ "${ZONES_COUNT}" == "0" ]]; then
  ZONES_STR="[]"
elif [[ "${ZONES_COUNT}" == "1" ]]; then
  function join_by { local IFS="$1"; shift; echo "$*"; }
  ZONES=("${ZONES[@]:0:${ZONES_COUNT}}")
  ZONES_STR="[ "
  ZONES_STR+=$(join_by , "${ZONES[@]}")
  ZONES_STR+=" ]"
else
  # For now, we only support a cluster within a single AZ.
  # This will change in the future.
  echo "Wrong ZONE_COUNT, can only be 0 or 1, got ${ZONES_COUNT}"
  exit 1
fi
echo "OpenStack Availability Zones: ${ZONES_STR}"

cat > "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: ${NETWORK_TYPE}
EOF
if [[ "${CONFIG_TYPE}" == "byon" ]]; then
cat >> "${CONFIG}" << EOF
  machineNetwork:
  - cidr: $(<"${SHARED_DIR}"/MACHINESSUBNET_SUBNET_RANGE)
EOF
fi
cat >> "${CONFIG}" << EOF
platform:
  openstack:
    cloud:             ${OS_CLOUD}
    computeFlavor:     ${OPENSTACK_COMPUTE_FLAVOR}
EOF
if [[ "${CONFIG_TYPE}" == "minimal" ]]; then
cat >> "${CONFIG}" << EOF
    externalDNS:
      - 1.1.1.1
      - 1.0.0.1
    lbFloatingIP:      ${API_IP}
    ingressFloatingIP: ${INGRESS_IP}
    externalNetwork:   ${OPENSTACK_EXTERNAL_NETWORK}
EOF
elif [[ "${CONFIG_TYPE}" == "byon" ]]; then
cat >> "${CONFIG}" << EOF
    machinesSubnet:    $(<"${SHARED_DIR}"/MACHINESSUBNET_SUBNET_ID)
    apiVIP:            ${API_IP}
    ingressVIP:        ${INGRESS_IP}
EOF
fi
cat >> "${CONFIG}" << EOF
compute:
- name: worker
  platform:
    openstack:
      type: ${OPENSTACK_COMPUTE_FLAVOR}
      zones: ${ZONES_STR}
  replicas: 3
controlPlane:
  name: master
  platform:
    openstack:
      type: ${OPENSTACK_COMPUTE_FLAVOR}
      zones: ${ZONES_STR}
  replicas: 3
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF

if [ ${FIPS_ENABLED} = "true" ]; then
  echo "Adding 'fips: true' to install-config.yaml"
  cat >> "${CONFIG}" << EOF
fips: true
EOF
fi

# Lets  check the syntax of yaml file by reading it.
python -c 'import yaml;
import sys;
data = yaml.safe_load(open(sys.argv[1]))' "${SHARED_DIR}/install-config.yaml"

# This block will remove the ports created in openstack-provision-machinesubnet-commands.sh
# since the installer will create them again, based on install-config.yaml.
if [[ ${OPENSTACK_PROVIDER_NETWORK} != "" ]]; then
  echo "Provider network detected, will clean-up reserved ports"
  for p in api ingress; do
    if openstack port show ${CLUSTER_NAME}-${p} >/dev/null; then
      echo "Port exists for $p: removing it"
      openstack port delete ${CLUSTER_NAME}-${p}
    fi
  done
fi
