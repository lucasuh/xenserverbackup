#!/bin/bash -ue
# Xenserver backup script using snapshots (via exports) written for Host1
# Christian Bryn 2010 <chr.bryn@gmail.com>

## functions
function vmlist {
    # get, parse and return 'associative' array in format <vm label>:<vm uuid>
    # params: none
    local key=0
    local index=0
    local IFS="
"

    if [ "$backup_control_domain" == "true" ];
    then
        local vm_list=$( xe vm-list )
    else
        local vm_list=$( xe vm-list is-control-domain=false )
    fi

    local vm_list_array=(${vm_list})
    local vms=()

    # this looks a lot like Andy's script - thanks! :-))
    for line in ${vm_list_array[@]};
    do
            if [ "${line:0:4}" = "uuid" ]; then

                    uuid=`expr "$line" : '.*: \(.*\)$'`
                    label=`expr "${vm_list_array[key+1]}" : '.*: \(.*\)$'`
                    vms[index]="${label}:${uuid}"

                    let "index = $index+1"
            fi

            let "key = $key+1"
    done
    unset IFS
    echo "${vms[@]}"
}

function backup_vm {
    # backup xenserver vm
    # params: <vm-name:vm-uuid>
    host="${1}"
    label="${host%%:*}"
    # snapshot the mofo
    snap=$( xe vm-snapshot vm="${host##*:}" new-name-label=backup_$( date "+%Y-%m-%d" )  )
    xe template-param-set is-a-template=false uuid="${snap}" > /dev/null
    local backup_file_path="${backup_dir}/$( date "+%V" )/${label}"
    if [ ! -d "${backup_file_path}"  ]; then
        mkdir -p "${backup_file_path}" || { p_err "Could not create directory ${backup_file_path}!"; exit 1; }
    fi
    # export snapshot
    xe vm-export vm="${snap}" filename="${backup_file_path}/${label}-$( date "+%Y-%m-%d" ).xva" > /dev/null
    xe vm-uninstall uuid="${snap}" force=true > /dev/null
}

function read_config {
    # read config in a somewhat safer manner than just sourcing... ;--)
    #[ "${no_config_file}" != "true" -a -f "${config_file}" ] && source <( egrep "backup_all_vms=|backup_dir=|exception_list=|logfile=|logging=|mount_commanda=|uuids=|vm_names=" "${config_file}" )
    # the sourcing bit works in bash 4, but not in bash 3. darn. let's do something else
    if [ -f "${config_file}" ]; then  
        f=$(mktemp) ; trap "rm ${f} >/dev/null 2>&1" EXIT
        egrep "^backup_all_vms=|^backup_dir=|^exception_list=|^logfile=|^logging=|^mount_commanda=|^uuids=|^vm_names=" "${config_file}" > ${f}
        source ${f} 
        rm ${f} ; unset f
    fi
}

function p_err {
    # print errors
    # params: <string>
    local string="${@}"
    if [ "${logging}" == "true" ]; then
        printf "$[ error ] %s - %s\n" "$(date)" "${string}" >> ${logfile}
    else
        printf "${b:-}${red:-}[ error ]${t_reset:-} %s - %s\n" "$(date)" "${string}"
    fi
}

function p_info {
    # print info
    # params: <string>
    local string="${@}"
    if [ "${logging}" == "true" ]; then
        printf "[ info ] %s -  %s\n" "$(date)" "${string}" >> ${logfile}
    else
        printf "${b:-}${yellow:-}[ info ]${t_reset:-} %s - %s\n" "$(date)" "${string}"
    fi
}

function print_usage {
    cat <<EOF
Back up Xenserver instances using snapshots. Specify which instances to back up 
with -a for all, -u for uuids or by passing VM names directly.
Usage: ${0} [-a|-b <backup dir>|-c|-C <config file>|-d|-e "<exception list>"|-h|-m "<mount command>"|-u "<uuid> [...<uuid>]"|-w] [<vm-name> [...<vm-name>]]
    -a      Backup all VMs except control domain
    -b      Specify output directory
    -c      Backup control domain
    -C      Specify config file (defaults to ~/.xenserver-backup.cfg)
    -d      Dry run.
    -e      Space separated list of VMs that should not be backed up.
    -l      Enable/disable logging with 'true' or 'false'.
    -m      Mount command to run previous to running the backup.
    -u      Specify VMs to back up via uuid (not implemented)
    -w      Write parameters -a.-b,-e,-m as specified on the command line to 
            default config file path and exit. 

Examples:
    ${0} <vm-name>
    ${0} -b /srv/backup/ <vm-name> <vm-name>
    ${0} -b /mnt/backup/ -a -d
    ${0} -a -b /mnt/backup -e "<vm-name> <vm-name>"
    ${0} -a -b /mnt/backup -e "<vm-name> <vm-name>" -m 'mount -t nfs <ip>:/share /mnt/backup'
    ${0} -a -b /mnt/backup -e "<vm-name> <vm-name>" -m 'mount -t nfs <ip>:/share /mnt/backup' -w
EOF
}

# fancy terminal stuff 
if [ -t 1 ]; then
    exec 3>&2 2>/dev/null
    b=$( tput bold ) || true
    red=$( tput setf 4 ) || true
    green=$( tput setf 2 ) || true
    yellow=$( tput setf 6 ) || true
    t_reset=$( tput sgr0 ) || true
    exec 2>&3
fi

## init defaults
backup_all_vms="false"
backup_dir=""
backup_control_domain="false"
config_file=~/.xenserver-backup.cfg
dry_run="false"
exception_list=""
logfile=/var/log/xenserver-backup.log
logging="false"
mount_command=""
uuids=""
vm_names=""
writeconfig="false"

# override defaults, then let command line override the config file..
read_config

while getopts hCab:cde:l:L:m:nu:w o
do
    case $o in
        h)
            print_usage
            exit 0
            ;;
        l)
            logging="${OPTARG}"
            ;;
        a)
            backup_all_vms="true"
            ;;
        b)
            backup_dir="${OPTARG}"
            ;;
        c)
            backup_control_domain="true"
            ;;
        d)
            dry_run="true"
            ;;
        e)
            exception_list="${OPTARG}"
            ;;
        L)
            logfile="${OPTARG}"
            [ -f "${logfile}" -a "${writeconfig}" != "true" ] || { p_err "Logfile ${logfile} is not a file!"; exit 1; }
            ;;
        m)
            mount_command="${OPTARG}"
            [ "${backup_dir}" == "" ] && { p_err "No backup destination path given."; exit 1; }
            grep -q "${backup_dir}" <( echo "${mount_command}" ) || { p_err "mount command '${mount_command}' does not contain backup dir path '${backup_dir}'?"; exit 1; }
            ;;
        u)
            uuids="${OPTARG}"
            ;;
        w)
            writeconfig="true"
            ;;
        C)
            config_file="${OPTARG}"
            [ -f "${config_file}" -a "${writeconfig}" != "true" ] || { p_err "Config file ${config_file} is not a file"; exit 1; }
            read_config
            ;;
    esac
done

shift $(($OPTIND-1))

# we can write our own config - wuh!
if [ "${writeconfig}" == "true" ]; then
    logging="false"
    p_info "Writing/updating the following config to ${config_file} ..."
    cat <<EOF
backup_all_vms='${backup_all_vms}'
backup_dir='${backup_dir}'
exception_list='${exception_list}'
logfile='${logfile}'
logging='${logging}'
mount_command='${mount_command}'
uuids='${uuids}'
vm_names='${@}'
EOF
    printf "backup_all_vms='%s'\nbackup_dir='%s'\nexception_list='%s'\nlogfile='%s'\nlogging='%s'\nmount_command='%s'\nuuids='%s'\nvm_names='%s'\n" "${backup_all_vms:-}" "${backup_dir:-}" "${exception_list:-}" "${logfile:-}" "${logging:-}" "${mount_command:-}" "${uuids:-}" "${@:-}" > ${config_file}
    exit $?
fi

# some sanity checks etc
which xe >/dev/null 2>&1 || { p_err "xe not in path!"; exit 1; }
[ $# -eq 0 \
    -a "${backup_all_vms}" != "true" \
    -a "${uuids}" == "" \
    -a "${vm_names}" == "" ] && \
    { p_err "No VMs to back up, use -a, -u or pass vm names."; \
    print_usage ; exit; }
[ "${backup_dir}" == "" ] && { p_err "No backup destination path given."; exit 1; }
[ ! -d "${backup_dir}"  ] && { p_err "Backup path ${backup_dir} is not a directory"; exit 1; }

# 
[ "${logging}" == "true" ] && exec >>${logfile} 2>>${logfile}
## main
# this one should overrule config file parameter
[ "${@:-}" != "" ] && vm_names="${@}"

vm_list=$(vmlist)

for vm in ${vm_names:-} ${exception_list} ${uuids:-}; do
    [[ ! "${vm_list[@]}" =~ ${vm} ]] && { p_err "VM/UUID ${vm} does not exist!"; exit 1; }
done

# simple mount + verification routine if the mount command is set
if [ ! "${mount_command}" == "" -a "${dry_run}" == "false" ]; then
    ${mount_command}
    mount | grep -q "${backup_dir}" || { p_err "Backup dir ${backup_dir} is not mounted, exiting."; exit 1; }
fi

p_info "---------- Initiating backup run... ----------"
[ "${dry_run}" == "true" ] && p_info "Performing dry run, will not attempt to actually backup any VMs"
[ -t 1 -a "${logging}" == "true" ] && { logging="false"; p_info "Logging on, check log file $logfile for status."; logging="true"; }
# backup vms by name or uuid if not in the exception list
for vm in ${vm_list[@]}; do
    ## vm=hostname:uuid
    if [ "${vm_names:-}" != "" ]; then
        [[ ! "${vm_names}" =~ ${vm%%:*} ]] && continue
    fi
    if [ "${uuids:-}" != "" ]; then
        [[ ! "${uuids}" =~ ${vm##*:} ]] && continue
    fi
    [[ "${exception_list}" =~ ${vm%%:*} ]] && continue
    [[ "${exception_list}" =~ ${vm##*:} ]] && continue
    
    p_info "Backing up ${vm%%:*} with uuid ${vm##*:}"
    [ "${dry_run}" == "false" ] && backup_vm "${vm}"
done
p_info "Backup run ended."
