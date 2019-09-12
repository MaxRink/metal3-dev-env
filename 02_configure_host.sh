#!/usr/bin/env bash
set -xe

# shellcheck disable=SC1091
source lib/logging.sh
# shellcheck disable=SC1091
source lib/common.sh

# Generate user ssh key
if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
    ssh-keygen -f ~/.ssh/id_rsa -P ""
fi

# root needs a private key to talk to libvirt
# See tripleo-quickstart-config/roles/virtbmc/tasks/configure-vbmc.yml
if sudo [ ! -f /root/.ssh/id_rsa_virt_power ]; then
  sudo ssh-keygen -f /root/.ssh/id_rsa_virt_power -P ""
  sudo cat /root/.ssh/id_rsa_virt_power.pub | sudo tee -a /root/.ssh/authorized_keys
fi



mkdir -p "$IRONIC_DATA_DIR/html/images"
pushd "$IRONIC_DATA_DIR/html/images"
if [ ! -f ironic-python-agent.initramfs ]; then
    curl --insecure --compressed -L https://images.rdoproject.org/master/rdo_trunk/current-tripleo-rdo/ironic-python-agent.tar | tar -xf -
fi
CENTOS_IMAGE=CentOS-7-x86_64-GenericCloud-1901.qcow2
if [ ! -f ${CENTOS_IMAGE} ] ; then
    curl --insecure --compressed -O -L http://cloud.centos.org/centos/7/images/${CENTOS_IMAGE}
    md5sum ${CENTOS_IMAGE} | awk '{print $1}' > ${CENTOS_IMAGE}.md5sum
fi
popd

for IMAGE_VAR in IRONIC_IMAGE IRONIC_INSPECTOR_IMAGE ; do
    IMAGE=${!IMAGE_VAR}
    sudo "${CONTAINER_RUNTIME}" pull "$IMAGE"
done

for name in ironic ironic-inspector dnsmasq httpd mariadb; do
    sudo "${CONTAINER_RUNTIME}" ps | grep -w "$name$" && sudo "${CONTAINER_RUNTIME}" kill $name
    sudo "${CONTAINER_RUNTIME}" ps --all | grep -w "$name$" && sudo "${CONTAINER_RUNTIME}" rm $name -f
done

# set password for mariadb
mariadb_password="$(echo "$(date;hostname)"|sha256sum |cut -c-20)"


if [[ "${CONTAINER_RUNTIME}" == "podman" ]]; then
  # Remove existing pod
  if  sudo "${CONTAINER_RUNTIME}" pod exists ironic-pod ; then
      sudo "${CONTAINER_RUNTIME}" pod rm ironic-pod -f
  fi
  # Create pod
  sudo "${CONTAINER_RUNTIME}" pod create -n ironic-pod
  POD_NAME="--pod ironic-pod"
else
  POD_NAME=""
fi

mkdir -p "$IRONIC_DATA_DIR"

# Start dnsmasq, http, mariadb, and ironic containers using same image
sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name dnsmasq  ${POD_NAME} \
     -v "$IRONIC_DATA_DIR":/shared --entrypoint /bin/rundnsmasq "${IRONIC_IMAGE}"

sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name httpd ${POD_NAME} \
     -v "$IRONIC_DATA_DIR":/shared --entrypoint /bin/runhttpd "${IRONIC_IMAGE}"

sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name mariadb ${POD_NAME} \
     -v "$IRONIC_DATA_DIR":/shared --entrypoint /bin/runmariadb \
     --env MARIADB_PASSWORD="$mariadb_password" "${IRONIC_IMAGE}"

sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name ironic ${POD_NAME} \
     --env MARIADB_PASSWORD="$mariadb_password" \
     -v "$IRONIC_DATA_DIR":/shared "${IRONIC_IMAGE}"

# Start Ironic Inspector
sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name ironic-inspector ${POD_NAME} "${IRONIC_INSPECTOR_IMAGE}"
