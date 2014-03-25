#!/bin/bash

set -eux
set -o pipefail

USE_CACHE=${USE_CACHE:-0}
TE_DATAFILE=${1:?"A test environment description is required as \$1."}
UNDERCLOUD_DIB_EXTRA_ARGS=${UNDERCLOUD_DIB_EXTRA_ARGS:-'rabbitmq-server'}
### --include
## devtest_undercloud
## ==================


## #. Create your undercloud image. This is the image that the seed nova
##    will deploy to become the baremetal undercloud. $UNDERCLOUD_DIB_EXTRA_ARGS is
##    meant to be used to pass additional arguments to disk-image-create.
##    ::

NODE_ARCH=$(os-apply-config -m $TE_DATAFILE --key arch --type raw)
if [ ! -e $TRIPLEO_ROOT/undercloud.qcow2 -o "$USE_CACHE" == "0" ] ; then #nodocs
    $TRIPLEO_ROOT/diskimage-builder/bin/disk-image-create $NODE_DIST \
        -a $NODE_ARCH -o $TRIPLEO_ROOT/undercloud \
        baremetal boot-stack nova-baremetal os-collect-config dhcp-all-interfaces \
        neutron-dhcp-agent $DIB_COMMON_ELEMENTS $UNDERCLOUD_DIB_EXTRA_ARGS 2>&1 | \
        tee $TRIPLEO_ROOT/dib-undercloud.log
fi #nodocs

## #. Load the undercloud image into Glance:
##    ::

UNDERCLOUD_ID=$(load-image $TRIPLEO_ROOT/undercloud.qcow2)


## #. Set the public interface of the undercloud network node:
##    ::

NeutronPublicInterface=${NeutronPublicInterface:-'eth0'}

## #. Create secrets for the cloud. The secrets will be written to a file
##    (tripleo-undercloud-passwords by default) that you need to source into
##    your shell environment.
##    Note that you can also make or change these later and
##    update the heat stack definition to inject them - as long as you also
##    update the keystone recorded password. Note that there will be a window
##    between updating keystone and instances where they will disagree and
##    service will be down. Instead consider adding a new service account and
##    changing everything across to it, then deleting the old account after
##    the cluster is updated.
##    ::

setup-undercloud-passwords
source tripleo-undercloud-passwords

## #. Pull out needed variables from the test environment definition.
##    ::

POWER_MANAGER=$(os-apply-config -m $TE_DATAFILE --key power_manager --type raw)
POWER_KEY=$(os-apply-config -m $TE_DATAFILE --key ssh-key --type raw)
POWER_HOST=$(os-apply-config -m $TE_DATAFILE --key host-ip --type raw)
POWER_USER=$(os-apply-config -m $TE_DATAFILE --key ssh-user --type raw)

## #. Wait for the BM cloud to register BM nodes with the scheduler.

wait_for 60 1 [ "\$(nova hypervisor-stats | awk '\$2==\"count\" { print \$4}')" != "0" ]

## #. Deploy an undercloud.
##    ::

make -C $TRIPLEO_ROOT/tripleo-heat-templates undercloud-vm.yaml
heat stack-create -f $TRIPLEO_ROOT/tripleo-heat-templates/undercloud-vm.yaml \
    -P "PowerUserName=${POWER_USER}" \
    -P "AdminToken=${UNDERCLOUD_ADMIN_TOKEN}" \
    -P "AdminPassword=${UNDERCLOUD_ADMIN_PASSWORD}" \
    -P "GlancePassword=${UNDERCLOUD_GLANCE_PASSWORD}" \
    -P "HeatPassword=${UNDERCLOUD_HEAT_PASSWORD}" \
    -P "NeutronPassword=${UNDERCLOUD_NEUTRON_PASSWORD}" \
    -P "NovaPassword=${UNDERCLOUD_NOVA_PASSWORD}" \
    -P "BaremetalArch=${NODE_ARCH}" \
    -P "PowerManager=${POWER_MANAGER}" \
    -P "undercloudImage=${UNDERCLOUD_ID}" \
    -P "PowerSSHPrivateKey=${POWER_KEY}" \
    -P "PowerSSHHost=${POWER_HOST}" \
    -P "NeutronPublicInterface=${NeutronPublicInterface}" \
    undercloud

##    You can watch the console via virsh/virt-manager to observe the PXE
##    boot/deploy process.  After the deploy is complete, it will reboot into the
##    image.
## 
## #. Get the undercloud IP from 'nova list'
##    ::

echo "Waiting for the undercloud stack to be ready" #nodocs
wait_for_stack_ready 220 10 undercloud
UNDERCLOUD_IP=$(nova list | grep ctlplane | sed  -e "s/.*=\\([0-9.]*\\).*/\1/")

## #. We don't (yet) preserve ssh keys on rebuilds.
##    ::

ssh-keygen -R $UNDERCLOUD_IP

## #. Exclude the undercloud from proxies:
##    ::

set +u #nodocs
export no_proxy=$no_proxy,$UNDERCLOUD_IP
set -u #nodocs

## #. Export the undercloud endpoint and credentials to your test environment.
##    ::

UNDERCLOUD_ENDPOINT="http://$UNDERCLOUD_IP:5000/v2.0"
NEW_JSON=$(jq '.undercloud.password="'${UNDERCLOUD_ADMIN_PASSWORD}'" | .undercloud.endpoint="'${UNDERCLOUD_ENDPOINT}'" | .undercloud.endpointhost="'${UNDERCLOUD_IP}'"' $TE_DATAFILE)
echo $NEW_JSON > $TE_DATAFILE

## #. Source the undercloud configuration:
##    ::

source $TRIPLEO_ROOT/tripleo-incubator/undercloudrc

## #. Perform setup of your undercloud.
##    ::

init-keystone -p $UNDERCLOUD_ADMIN_PASSWORD $UNDERCLOUD_ADMIN_TOKEN \
    $UNDERCLOUD_IP admin@example.com heat-admin@$UNDERCLOUD_IP
setup-endpoints $UNDERCLOUD_IP --glance-password $UNDERCLOUD_GLANCE_PASSWORD \
    --heat-password $UNDERCLOUD_HEAT_PASSWORD \
    --neutron-password $UNDERCLOUD_NEUTRON_PASSWORD \
    --nova-password $UNDERCLOUD_NOVA_PASSWORD
keystone role-create --name heat_stack_user
# Creating these roles to be used by tenants using swift
keystone role-create --name=swiftoperator
keystone role-create --name=ResellerAdmin

user-config

setup-neutron 192.0.2.21 192.0.2.40 192.0.2.0/24 192.0.2.1 $UNDERCLOUD_IP ctlplane

## #. Register two baremetal nodes with your undercloud.
##    ::

setup-baremetal $TE_DATAFILE --service-host undercloud --not-first

### --end
