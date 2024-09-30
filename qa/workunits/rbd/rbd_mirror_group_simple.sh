#!/usr/bin/env bash
#
# rbd_mirror_group_simple.sh
#
# This script has a set of tests that should pass when run.
# It may repeat some of the tests from rbd_mirror_group.sh, but only those that are known to work
# It has a number of extra tests that imclude multiple images in a group
#

export RBD_MIRROR_NOCLEANUP=1
export RBD_MIRROR_TEMDIR=/tmp/tmp.rbd_mirror
export RBD_MIRROR_SHOW_CMD=1
export RBD_MIRROR_MODE=snapshot

. $(dirname $0)/rbd_mirror_helpers.sh

test_create_group_with_images_then_mirror()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local disable_before_remove=$5

  create_group "${primary_cluster}" ${pool} "${group}"
  create_images "${primary_cluster}" ${pool} ${image_prefix} 5
  group_add_images "${primary_cluster}" ${pool} "${group}" ${pool} ${image_prefix} 5

  enable_group_mirror "${primary_cluster}" ${pool} "${group}"

  # rbd group list poolName  (check groupname appears in output list)
  # do this before checking for replay_started because queries directed at the daemon fail with an unhelpful
  # error message before the group appears on the remote cluster
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 5
  check_daemon_running "${secondary_cluster}"

  # ceph --daemon mirror group status groupName
  wait_for_group_replay_started "${secondary_cluster}" "${pool}" "${group}" 5
  check_daemon_running "${secondary_cluster}"

  # rbd mirror group status groupName
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}" "${group}" 'up+replaying' 5

  check_daemon_running "${secondary_cluster}"
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}" "${group}" 'down+unknown' 5
  fi
  check_daemon_running "${secondary_cluster}"

  if [ 'false' != "${disable_before_remove}" ]; then
      disable_group_mirror "${primary_cluster}" "${pool}" "${group}"
  fi    

  remove_group "${primary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"

  remove_images_retry "${primary_cluster}" "${pool}" ${image_prefix} 5
}

test_create_group_mirror_then_add_images()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local disable_before_remove=$5

  create_group "${primary_cluster}" "${pool}" "${group}"

  enable_group_mirror "${primary_cluster}" "${pool}" "${group}"

  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 0
  wait_for_group_replay_started "${secondary_cluster}" "${pool}" "${group}" 0
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}" "${group}" 'up+replaying' 0
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}" "${group}" 'down+unknown' 0
  fi

  create_images "${primary_cluster}" "${pool}" ${image_prefix} 5
  group_add_images "${primary_cluster}" "${pool}" "${group}" "${pool}" ${image_prefix} 5

  # rbd group list poolName  (check groupname appears in output list)
  # do this before checking for replay_started because queries directed at the daemon fail with an unhelpful
  # error message before the group appears on the remote cluster
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 5
  check_daemon_running "${secondary_cluster}"

  # ceph --daemon mirror group status groupName
  wait_for_group_replay_started "${secondary_cluster}" "${pool}" "${group}" 5
  check_daemon_running "${secondary_cluster}"

  # rbd mirror group status groupName
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}" "${group}" 'up+replaying' 5

  check_daemon_running "${secondary_cluster}"
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}" "${group}" 'down+unknown' 5
  fi
  check_daemon_running "${secondary_cluster}"

  if [ 'false' != "${disable_before_remove}" ]; then
      disable_group_mirror "${primary_cluster}" "${pool}" "${group}"
  fi    

  remove_group "${primary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"

  remove_images_retry "${primary_cluster}" "${pool}" ${image_prefix} 5
}

test_empty_group()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4

  create_group_and_enable_mirror "${primary_cluster}" "${pool}" "${group}"
  # rbd group list poolName  (check groupname appears in output list)
  # do this before checking for replay_started because queries directed at the daemon fail with an unhelpful
  # error message before the group appears on the remote cluster
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"

  # ceph --daemon mirror group status groupName
  wait_for_group_replay_started "${secondary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"

  # rbd mirror group status groupName
  wait_for_group_status_in_pool_dir "${secondary_cluster}" ${pool} "${group}" 'up+replaying' 0

  check_daemon_running "${secondary_cluster}"
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" ${pool} "${group}" 'down+unknown' 0
  fi
  check_daemon_running "${secondary_cluster}"

  try_cmd "rbd --cluster ${secondary_cluster} group snap list mirror/test-group"
  try_cmd "rbd --cluster ${primary_cluster} group snap list mirror/test-group"

  disable_group_mirror "${primary_cluster}" "${pool}" "${group}"

  # Need to wait for snaps to be deleted otherwise rbd-mirror segfaults when the group is removed TODO - remove
  sleep 5 
  try_cmd "rbd --cluster ${secondary_cluster} group snap list mirror/test-group"
  try_cmd "rbd --cluster ${primary_cluster} group snap list mirror/test-group"

  remove_group "${primary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"
}

set -e

# If the tmpdir or cluster conf file doesn't exist then assume that the cluster needs setting up
if [ ! -d "${RBD_MIRROR_TEMDIR}" ] || [ ! -f "${RBD_MIRROR_TEMDIR}"'/cluster1.conf' ]
then
    setup
fi
export RBD_MIRROR_USE_EXISTING_CLUSTER=1

# rbd_mirror_helpers assumes that we are running from tmpdir
cd "${RBD_MIRROR_TEMDIR}"
 
# see if we need to (re)start rbd-mirror deamon 
pid=$(cat "$(daemon_pid_file "${CLUSTER1}")" 2>/dev/null) || :
if [ -z "${pid}" ] 
then
    start_mirrors "${CLUSTER1}"
fi
check_daemon_running "${CLUSTER1}"

group=test-group
image_prefix=test-image

: '
testlog "TEST: empty group"
test_empty_group "${CLUSTER2}" "${CLUSTER1}" "${POOL}" "${group}"
testlog "TEST: empty group with namespace"
test_empty_group "${CLUSTER2}" "${CLUSTER1}" "${POOL}"/"${NS1}" "${group}"
testlog "TEST: create group with images then enable mirroring.  Remove group without disabling mirroring"
test_create_group_with_images_then_mirror "${CLUSTER2}" "${CLUSTER1}" "${POOL}" "${group}" 'false'
testlog "TEST: create group with images then enable mirroring.  Disable mirroring then remove group"
test_create_group_with_images_then_mirror "${CLUSTER2}" "${CLUSTER1}" "${POOL}" "${group}" 'true'

'
# these next 2 tests sometime fall over with 808 assert that Prasanna knows about
testlog "TEST: create group then enable mirroring before adding images to the group.  Remove group without disabling mirroring"
test_create_group_mirror_then_add_images "${CLUSTER2}" "${CLUSTER1}" "${POOL}" "${group}" 'false'
#testlog "TEST: create group then enable mirroring before adding images to the group.  Disable mirroring then remove group"
#test_create_group_mirror_then_add_images "${CLUSTER2}" "${CLUSTER1}" "${POOL}" "${group}" 'true'

exit 0