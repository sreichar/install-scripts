#!/usr/bin/env bash
set -xe

source ../common/logging.sh
source common.sh

export KUBECONFIG=${KUBECONFIG:-ocp/auth/kubeconfig}
POSTINSTALL_ASSETS_DIR="./assets/post-install"
IFCFG_INTERFACE="${POSTINSTALL_ASSETS_DIR}/ifcfg-interface.template"
IFCFG_BRIDGE="${POSTINSTALL_ASSETS_DIR}/ifcfg-bridge.template"
BREXT_FILE="${POSTINSTALL_ASSETS_DIR}/99-brext-master.yaml"

export bridge="${bridge:-brext}"

create_bridge(){
  echo "Deploying Bridge ${bridge}..."

  FIRST_MASTER=$(oc get node -o custom-columns=IP:.status.addresses[0].address --no-headers | head -1)
  export interface=$(ssh -q -o StrictHostKeyChecking=no core@$FIRST_MASTER "ip r | grep default | grep -Po  '(?<=dev )(\S+)'")
  if [ "$interface" == "" ] ; then
    echo "Issue detecting interface to use! Leaving..."
    exit 1
  fi
  if [ "$interface" != "$bridge" ] ; then
    echo "Using interface $interface"
    export interface_content=$(envsubst < ${IFCFG_INTERFACE} | base64 -w0)
    export bridge_content=$(envsubst < ${IFCFG_BRIDGE} | base64 -w0)
    envsubst < ${BREXT_FILE}.template > ${BREXT_FILE}
    echo "Done creating bridge definition"
  else
    echo "Bridge already there!"
  fi
}

apply_mc(){
  # Disable auto reboot hosts in order to apply several mcos at the same time
  for node_type in master worker; do
    oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/${node_type}
  done

  # Add extra registry if needed (this applies clusterwide)
  # https://docs.openshift.com/container-platform/4.1/openshift_images/image-configuration.html#images-configuration-insecure_image-configuration
  if [ "${EXTRA_REGISTRY}" != "" ] ; then
    echo "Adding ${EXTRA_REGISTRY}..."
    oc patch image.config.openshift.io/cluster --type merge --patch "{\"spec\":{\"registrySources\":{\"insecureRegistries\":[\"${EXTRA_REGISTRY}\"]}}}"
  fi

  # Apply machine configs
  for node_type in master worker; do
    if test $(find "${POSTINSTALL_ASSETS_DIR}" -iname "*-${node_type}.yaml" -type f); then
      echo "Applying machine configs..."
      oc create -f ${POSTINSTALL_ASSETS_DIR}/*-${node_type}.yaml
    fi
    # Enable auto reboot
    oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/${node_type}

    echo "Rebooting nodes..."
    # This sleep is required because the machine-config changes are not immediate
    sleep 30

    # The 'while' is required because in the process of rebooting the masters, the
    # oc wait connection is lost a few times, which is normal
    while ! oc wait mcp/${node_type} --for condition=updated --timeout 600s ; do sleep 1 ; done
  done
}

function start_autoapprover() {
  oc create -f  ${POSTINSTALL_ASSETS_DIR}/autoapprover.yaml
}

start_autoapprover
./add-machine-ips.sh
create_bridge
apply_mc
