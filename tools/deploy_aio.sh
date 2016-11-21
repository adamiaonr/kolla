#!/bin/bash

set -o xtrace
set -o errexit

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export KOLLA_BASE=$1
export KOLLA_TYPE=$2
export KEEPALIVED_VIRTUAL_ROUTER_ID=$(shuf -i 1-255 -n 1)
export KOLLA_ANSIBLE_DIR=$(mktemp -d)

function prepare_kolla_ansible {
    cat > /tmp/clonemap <<EOF
clonemap:
 - name: openstack/kolla-ansible
   dest: ${KOLLA_ANSIBLE_DIR}
EOF
    /usr/zuul-env/bin/zuul-cloner -m /tmp/clonemap --workspace "$(pwd)" \
        --cache-dir /opt/git git://git.openstack.org \
        openstack/kolla-ansible
    pip install ${KOLLA_ANSIBLE_DIR}
}

function copy_logs {
    cp -rnL /var/lib/docker/volumes/kolla_logs/_data/* /tmp/logs/kolla/
    cp -rnL /etc/kolla/* /tmp/logs/kolla_configs/
    cp -rvnL /var/log/* /tmp/logs/system_logs/


    if [[ -x "$(command -v journalctl)" ]]; then
        journalctl --no-pager -u docker.service > /tmp/logs/system_logs/docker.log
    else
        cp /var/log/upstart/docker.log /tmp/logs/system_logs/docker.log
    fi

    # NOTE(SamYaple): Fix permissions for log extraction in gate
    chmod -R 777 /tmp/logs/kolla /tmp/logs/kolla_configs /tmp/logs/system_logs
    ara generate /tmp/logs/playbook_reports/
}

function sanity_check {
    # Wait for service ready
    sleep 15
    . /etc/kolla/admin-openrc.sh
    # TODO(Jeffrey4l): Restart the memcached container to cleanup all cache.
    # Remove this after this bug is fixed
    # https://bugs.launchpad.net/oslo.cache/+bug/1590779
    docker restart memcached
    nova --debug service-list
    neutron --debug agent-list
    ${KOLLA_ANSIBLE_DIR}/tools/init-runonce
    nova --debug boot --poll --image $(openstack image list | awk '/cirros/ {print $2}') --nic net-id=$(openstack network list | awk '/demo-net/ {print $2}') --flavor 1 kolla_boot_test
    nova --debug list
    # If the status is not ACTIVE, print info and exit 1
    nova --debug show kolla_boot_test | awk '{buf=buf"\n"$0} $2=="status" && $4!="ACTIVE" {failed="yes"}; END {if (failed=="yes") {print buf; exit 1}}'
}

function check_failure {
    # Command failures after this point can be expected
    set +o errexit

    docker images
    docker ps -a
    failed_containers=$(docker ps -a --format "{{.Names}}" --filter status=exited)

    for failed in ${failed_containers}; do
        docker logs --tail all ${failed}
    done

    copy_logs
}

function write_configs {
    mkdir -p /etc/kolla/config

    PRIVATE_ADDRESS=$(cat /etc/nodepool/node_private)
    PRIVATE_INTERFACE=$(ip -4 --oneline address | awk -v pattern=${PRIVATE_ADDRESS} '$0 ~ pattern {print $2}')
    cat << EOF > /etc/kolla/globals.yml
---
kolla_base_distro: "${KOLLA_BASE}"
kolla_install_type: "${KOLLA_TYPE}"
kolla_internal_vip_address: "169.254.169.10"
keepalived_virtual_router_id: "${KEEPALIVED_VIRTUAL_ROUTER_ID}"
docker_restart_policy: "never"
# NOTE(Jeffrey4l): use different a docker namespace name in case it pull image from hub.docker.io when deplying
docker_namespace: "lokolla"
network_interface: "${PRIVATE_INTERFACE}"
neutron_external_interface: "fake_interface"
openstack_release: "4.0.0"
enable_horizon: "no"
enable_heat: "no"
openstack_logging_debug: "True"
openstack_service_workers: "1"
EOF

    mkdir /etc/kolla/config/nova
    cat << EOF > /etc/kolla/config/nova/nova-compute.conf
[libvirt]
virt_type=qemu
EOF
}

trap check_failure EXIT

prepare_kolla_ansible
write_configs

# Create dummy interface for neutron
ip l a fake_interface type dummy

# Actually do the deployment
kolla-ansible -vvv prechecks
# TODO(jeffrey4l): add pull action when we have a local registry
# service in CI
kolla-ansible -vvv deploy
kolla-ansible -vvv post-deploy

# Test OpenStack Environment
sanity_check

# TODO(jeffrey4l): make some configure file change and
# trigger a real reconfigure
kolla-ansible -vvv reconfigure
# TODO(jeffrey4l): need run a real upgrade
kolla-ansible -vvv upgrade
