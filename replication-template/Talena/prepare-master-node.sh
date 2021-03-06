#!/bin/bash

#
# Script to prepare Talena InstallMaster node
#

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source ${SCRIPT_DIR}/common-funcs.sh
source ${TALENA_ENV}

NODE_COUNT=
VM_BASENAME=
CLUSTER_NODES=
MIN_REQUIRED_NODES=3
TALENA_SUPPORT_EMAIL=rjorapur@talena-inc.com,hmankude@talena-inc.com
ARGS=$*

echo "log location : ${LOG_FILE}"

# logs everything to the $LOG_FILE
log() {
  EXECNAME="prepare-master-node"
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}       
            
exit_function()
{
    local ret=$1
    log "Exiting with retcode : ${ret}"
    send_email ${ARGS}
    exit ${ret}
}

parse_arguments()
{
    while [ "$1" != "" ]; do
        case $1 in
            -nodeCount) shift
                NODE_COUNT=$1
                log "DEBUG: NODE_COUNT=$NODE_COUNT"
                ;;
            -vmBasename) shift
                VM_BASENAME=$1
                log "DEBUG: VM_BASENAME=$VM_BASENAME"
                ;;
        esac
        shift
    done
    
    if [ -z "${NODE_COUNT}" -o -z "${VM_BASENAME}" ]
    then
        log "ERROR: No values found for -nodeCount/-vmBasename" 
        exit_function 1   
    fi
}

# send email to talena with Talena cluster
# invocation parameters on Azure
send_email()
{
    local stringToPrint=
    local emailSubject="Notification : Talena Azure Cluster Deployment"
    while [ "$1" != "" ]; do
        key=$1
        shift
        val=$1
        shift
        stringToPrint="${stringToPrint}\n${key}=${val}"
    done
    cp -f ${LOG_FILE} ${LOG_FILE}.txt
    printf "${stringToPrint}" | mailx -v -s "${emailSubject}" -a "${LOG_FILE}.txt" ${TALENA_SUPPORT_EMAIL} >>${LOG_FILE} 2>&1
}

populate_cluster_nodes()
{
    # generate hostnames using nodeCount
    # nodenames will be generated by adding nodecount
    # (starting from 0-nodeCount) at the end of vmbasename
    local nodeCount=${NODE_COUNT}
    if [ "${nodeCount}" -lt "${MIN_REQUIRED_NODES}" ]
    then
        log "ERROR: Minimum required nodes ${MIN_REQUIRED_NODES}, available ${nodeCount}"
        exit_function 1
    fi

    let nodeCount=${nodeCount}-1
    for i in `eval echo {0..$nodeCount}`
    do
        CLUSTER_NODES="${CLUSTER_NODES} ${VM_BASENAME}${i}"
    done
    export CLUSTER_NODES=`echo ${CLUSTER_NODES} | xargs | tr " " ","`
    log "INFO: CLUSTER_NODES=${CLUSTER_NODES}"
    export UI_NODE=`echo ${CLUSTER_NODES} | cut -d',' -f1` 
    log "INFO: UI_NODE=${UI_NODE}"
}

populate_dir_paths()
{
    local mountPoints=
    # Find all mount points from cluster node
    # leave one mount point for namenode/journalnode/logs
    # Assign remaining mount points to datanode
    mountPoints=`grep ${MOUNT_BASENAME} /proc/mounts | awk '{print $2}' | sort -V`
    export DATANODE_DIRS=`echo ${mountPoints} | cut -d" " -f2- | tr " " ","`
    log "INFO: DATANODE_DIRS=${DATANODE_DIRS}"
    otherServicesDir=`echo ${mountPoints} | cut -d" " -f1`
    export NAMENODE_DIR=${otherServicesDir}
    log "INFO: NAMENODE_DIR=${NAMENODE_DIR}"
    export JOURNALNODE_DIR=${otherServicesDir}
    log "INFO: JOURNALNODE_DIR=${JOURNALNODE_DIR}"
    export LOG_DIR=${otherServicesDir}
    log "INFO: LOG_DIR=${LOG_DIR}"
    export TALENA_DATA_DIR=${otherServicesDir}
    log "INFO: TALENA_DATA_DIR=${TALENA_DATA_DIR}"
    export PID_DIR=${otherServicesDir}
    log "INFO: PID_DIR=${PID_DIR}"
    export CORE_DIR=${otherServicesDir}
    log "INFO: CORE_DIR=${CORE_DIR}"
    export YARN_TMP_DIR=${otherServicesDir}
    log "INFO: YARN_TMP_DIR=${YARN_TMP_DIR}"
    export ZK_DATADIR=${otherServicesDir}
    log "INFO: ZK_DATADIR=${ZK_DATADIR}"
}

prepare_installer_conf()
{
    local conf_path=${INSTALL_DIR}/${TALENA_VERSION}/conf/tl_installer.conf
    local advanced_conf_path=${INSTALL_DIR}/${TALENA_VERSION}/conf/.tl_installer_advanced.conf
    declare -A CONF_TO_VALUE_MAP

    # update tl_installer.conf with required values
    CONF_TO_VALUE_MAP["tl_physical_nodes"]="${CLUSTER_NODES}"
    CONF_TO_VALUE_MAP["tl_datanode_dirlist"]="${DATANODE_DIRS}"
    CONF_TO_VALUE_MAP["tl_namenode_dir"]="${NAMENODE_DIR}"
    CONF_TO_VALUE_MAP["tl_journalnode_localdir"]="${JOURNALNODE_DIR}"
    CONF_TO_VALUE_MAP["tl_log_dir"]="${LOG_DIR}"
    CONF_TO_VALUE_MAP["tl_talenadata_dir"]="${TALENA_DATA_DIR}"
    CONF_TO_VALUE_MAP["tl_pid_dir"]="${PID_DIR}"
    CONF_TO_VALUE_MAP["tl_core_dir"]="${CORE_DIR}"
    CONF_TO_VALUE_MAP["tl_zk_datadir"]="${ZK_DATADIR}"
    CONF_TO_VALUE_MAP["tl_yarn_nodemgr_localdir"]="${YARN_TMP_DIR}"
    CONF_TO_VALUE_MAP["tl_use_ssh"]="false"
    CONF_TO_VALUE_MAP["tl_ui_node"]="${UI_NODE}"
    CONF_TO_VALUE_MAP["tl_continue_on_failure"]="True"

    log "INFO: Preparing conf file for Talena installation."
    for key in ${!CONF_TO_VALUE_MAP[@]} 
    do
        log "INFO: Processing key : ${key}"
        for file in ${conf_path} ${advanced_conf_path} 
        do
            grep ${key}= ${file} >/dev/null
            if [ $? -eq 0 ]
            then
                val=${CONF_TO_VALUE_MAP[${key}]}
                log "DEBUG: setting ${key}=${val} in ${file}"
                sed -i "s|^${key}=.*|${key}=${val}|" ${file} 
            fi
        done
    done
}

setup_talena_cluster()
{
    local install_script_path=${INSTALL_DIR}/${TALENA_VERSION}/install_talena.sh
    local ret=0
    log "INFO: Setting up Talena cluster"
    
    cd ${INSTALL_DIR}/${TALENA_VERSION}  
    ${install_script_path} --expand -q -n smoketest
    ret=$?
    
    return ${ret}
    
}

log "------------- Preparing master node - start ----------------"

parse_arguments ${ARGS}

# start RPyC and mount disks
sudo bash -c "source ./common-funcs.sh; prepare_talena_node ${NODE_COUNT} ${VM_BASENAME}" >>${LOG_FILE} 2>&1
if [ $? -ne 0 ]
then
    log "ERROR: Failed to prepare Talena node"
    exit_function 1
fi

# generate conf values
populate_cluster_nodes
populate_dir_paths

# generate tl_installer.conf
sudo -E bash -c "$(declare -f prepare_installer_conf log); prepare_installer_conf" >>${LOG_FILE} 2>&1

# setup Talena cluster
sudo -E bash -c "$(declare -f setup_talena_cluster log) ; setup_talena_cluster" >>${LOG_FILE} 2>&1
ret=$?
log "------------- Preparing master node - end ----------------"
if [ ${ret} -ne 0 ]
then
    log "ERROR: Failed to prepare Talena master node"
fi
exit_function ${ret}
