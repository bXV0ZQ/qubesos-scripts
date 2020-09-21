#!/usr/bin/bash

SCRIPT_NAME=$(basename $0)

#
# CONFIGURATION
#

# Enums
declare -r OBJECT_TYPE_PILLAR="pillars"
declare -r OBJECT_TYPE_FORMULA="formulas"
declare -r OBJECT_TYPE_STATE="states"
declare -r OBJECT_TYPE_ALL="all"

# Default values
declare -r DEF_SALT_ROOT="myq"
declare -r DEF_SRC_DIR="/home/user/Documents"

# Configuration
declare -r SALT_CONF_FOLDER="/etc/salt"
declare -r PILLARS_FOLDER="qubesos-pillars"
declare -r PILLARS_DST_BASE_DIR="/srv/pillar"
declare -r FORMULAS_FOLDER="qubesos-formulas"
declare -r FORMULAS_DST_BASE_DIR="/srv/formulas"
declare -r STATES_FOLDER="qubesos-states"
declare -r STATES_DST_BASE_DIR="/srv/salt"

#
# UTILS
#

RED="\\033[1;31m"
GREEN="\\033[1;32m"
YELLOW="\\033[1;33m"
BLUE="\\033[1;34m"
MAGENTA="\\033[1;35m"
CYAN="\\033[1;36m"
BOLD="\\033[1m"
END="\\033[1;00m"
FATAL="\\033[1;37;41m" # WHITE on RED

print_info () {
    echo -e "${GREEN} [INFO]${END} $@"
}

print_error () {
    echo -e "${RED} [ERROR]${END} $@"
}

print_warn () {
    echo -e "${YELLOW} [WARN]${END} $@"
}

print_step () {
    echo -e "${MAGENTA} >>>${END} $@"
}

print_sub_step () {
    echo -e "${MAGENTA} >>>>>>${END} $@"
}


usage () {
    local USAGE

# \n is required to preserve whitespaces for the first line (and adding a new line before printing the usage message is a good deal)
    read -r -d '' USAGE << EOM
\n    Usage: ${SCRIPT_NAME} <domain> [-o <object_type>] [-r <salt_root>] [-s <source>]

    Copy ${YELLOW}pillars${END}, ${YELLOW}formulas${END} and/or ${YELLOW}states${END} from ${BOLD}<domain>${END} to dom0 then enable them.

    Parameters:
        ${BOLD}<domain>${END} must be a valid and started AppVM, as safe as possible
    
    Options:
        -o|--object-type ${BOLD}<object_type>${END}
            The type of object to sync (default: '${OBJECT_TYPE_ALL}'):
                - '${OBJECT_TYPE_PILLAR}': Synchronize pillars only (from '${PILLARS_FOLDER}')
                - '${OBJECT_TYPE_FORMULA}': Synchronize formulas only (from '${FORMULAS_FOLDER}')
                - '${OBJECT_TYPE_STATE}': Synchronize states only (from '${STATES_FOLDER}')
                - '${OBJECT_TYPE_ALL}': Synchronize both pillars and formulas (from their respective folders)
        
        -r|--salt-root ${BOLD}<salt_root>${END}
            The Salt root name (default: '${SALT_ROOT}')
            Limited to alphanumeric, '.', '-' and '_' characters
            Must start by an alphabetic character
        
        -s|--source ${BOLD}<source>${END}
            The path to pillars and formulas folders on domain ${BOLD}<domain>${END} (default: '${SRC_DIR}')
            Limited to alphanumeric, '.', '-', '_', ' ' and '/' characters
            Must start by a '/' character (absolute path)
    
    Others:
        -h|--help: print this help message

EOM
    echo -e "${USAGE}"
}

#
# RETRIEVE INPUT
#

# Need help?
case "$1" in
    "-h"|"--help") usage && exit 0;;
esac

# Require root privileges
if [[ "$EUID" -ne 0 ]]; then
    print_error "Requires root privileges (please use sudo)" && usage && exit 1
fi

# Retrieve mandatory arguments
if [[ $# -ge 1 ]]; then
    QDOMAIN=$1
    shift
else
    print_error "Missing domain" && usage && exit 1
fi

# Look for options
while [[ -n "$1" ]]; do
    case "$1" in
        "-o"|"--object-type")
            if [[ $# -ge 2 ]]; then
                ARG_OBJECT_TYPE="$2"
                shift 2
            else
                print_error "Missing object type after '$1'" && usage && exit 1
            fi
            ;;
        "-r"|"--salt-root")
            if [[ $# -ge 2 ]]; then
                ARG_SALT_ROOT="$2"
                shift 2
            else
                print_error "Missing salt root after '$1'" && usage && exit 1
            fi
            ;;
        "-s"|"--source")
            if [[ $# -ge 2 ]]; then
                ARG_SOURCE="$2"
                shift 2
            else
                print_error "Missing source after '$1'" && usage && exit 1
            fi
            ;;
        "-h"|"--help") usage && exit 0;;
        *) print_error "Unknown command '$1'" && usage && exit 1;;
    esac
done

# Prepare options
OBJECT_TYPE=${ARG_OBJECT_TYPE:-${OBJECT_TYPE_ALL}}
SALT_ROOT=${ARG_SALT_ROOT:-${DEF_SALT_ROOT}}
SRC_DIR=${ARG_SOURCE:-${DEF_SRC_DIR}}

#
# INPUT VALIDATION
#

# Check the script is executed on dom0
if [ "${HOSTNAME}" != "dom0" ]; then
    print_error "This script must be executed on 'dom0'" && exit 1
fi

# Check if domain exists and is started
qvm-check --quiet --running "${QDOMAIN}" 2> /dev/null
case "$?" in
    0) print_info "Ready to sync dom0 from '${QDOMAIN}'";;
    1) print_error "Domain '${QDOMAIN}' is not started" && exit 1;;
    2) print_error "Domain '${QDOMAIN}' doesn't exist" && exit 1;;
    *) print_error "Unknown feedback '$?' from qvm-check for domain '${QDOMAIN}'" && exit 1;;
esac

# Validate OBJECT_TYPE
case "${OBJECT_TYPE}" in
    "${OBJECT_TYPE_PILLAR}")
        sync_pillars=true
        ;;
    "${OBJECT_TYPE_FORMULA}")
        sync_formulas=true
        ;;
    "${OBJECT_TYPE_STATE}")
        sync_states=true
        ;;
    "${OBJECT_TYPE_ALL}")
        sync_pillars=true
        sync_formulas=true
        sync_states=true
        ;;
    *) print_error "Invalid object type: '${OBJECT_TYPE}'" && usage && exit 1;;
esac

# Validate SALT_ROOT
[[ "${SALT_ROOT}" =~ [^a-zA-Z0-9_.-]+ ]] && print_error "Invalid salt root (bad characters): '${SALT_ROOT}'" && usage && exit 1
[[ "${SALT_ROOT}" =~ ^[^a-zA-Z] ]] && print_error "Invalid salt root (bad starting character): '${SALT_ROOT}'" && usage && exit 1

# Validation SRC_DIR
[[ "${SRC_DIR}" =~ [^a-zA-Z0-9\ /_.-]+ ]] && print_error "Invalid source (bad characters): '${SRC_DIR}'" && usage && exit 1
[[ "${SRC_DIR}" =~ ^[^/] ]] && print_error "Invalid source (bad starting character): '${SRC_DIR}'" && usage && exit 1

#
# MAIN PROCESS
#

if [[ "${sync_pillars}" == true ]]; then
    print_step "Syncing pillars"

    # Create pillars folder if needed
    mkdir -p "${PILLARS_DST_BASE_DIR}"

    # Disable pillars
    print_sub_step "Disable pillars"

    qubesctl top.disable "${SALT_ROOT}" pillar=true

    # Clean up pillars
    print_sub_step "Clean pillars"

    rm -fr "${PILLARS_DST_BASE_DIR}/${SALT_ROOT}"

    # Retrieve pillars
    print_sub_step "Retrieve pillars"

    PILLARS_SRC_DIR="${SRC_DIR}/${PILLARS_FOLDER}"
    PILLARS_ARCHIVE="${PILLARS_DST_BASE_DIR}/${SALT_ROOT}.tgz"

    qvm-run --pass-io ${QDOMAIN} "tar czf - -C ${PILLARS_SRC_DIR} ${SALT_ROOT}" > "${PILLARS_ARCHIVE}"
    tar xzf "${PILLARS_ARCHIVE}" -C "${PILLARS_DST_BASE_DIR}" && rm "${PILLARS_ARCHIVE}"

    # Enable pillars
    print_sub_step "Enable pillars"

    qubesctl top.enable "${SALT_ROOT}" pillar=true

fi

if [[ "${sync_formulas}" == true ]]; then
    print_step "Syncing formulas"

    # Create formulas folder if needed
    mkdir -p "${FORMULAS_DST_BASE_DIR}"

    # Prepare formulas folder and configuration file
    FORMULAS_DST_DIR="${FORMULAS_DST_BASE_DIR}/${SALT_ROOT}"
    FORMULAS_CONFIG="${SALT_CONF_FOLDER}/minion.d/${SALT_ROOT}.conf"

    # Disable formulas
    print_sub_step "Disable formulas"

    rm -fr "${FORMULA_CONFIG}"

    # Clean up formulas
    print_sub_step "Clean formulas"

    rm -fr "${FORMULAS_DST_DIR}"
    mkdir -p "${FORMULAS_DST_DIR}"

    # Retrieve formulas
    print_sub_step "Retrieve formulas"

    FORMULAS_SRC_DIR="${SRC_DIR}/${FORMULAS_FOLDER}"
    FORMULAS_ARCHIVE="${FORMULAS_DST_DIR}/${SALT_ROOT}.tgz"

    qvm-run --pass-io ${QDOMAIN} "tar czf - -C ${FORMULAS_SRC_DIR} \$(cd ${FORMULAS_SRC_DIR}; echo *-formula/${SALT_ROOT}/*)" > "${FORMULAS_ARCHIVE}"
    tar xzf "${FORMULAS_ARCHIVE}" -C "${FORMULAS_DST_DIR}" && rm "${FORMULAS_ARCHIVE}"

    # Enable formulas
    print_sub_step "Enable formulas"

    echo "file_roots:" > "${FORMULAS_CONFIG}"
    echo "  base:" >> "${FORMULAS_CONFIG}"
    for formula in ${FORMULAS_DST_DIR}/*; do
    echo "    - ${formula}" >> "${FORMULAS_CONFIG}"
    done

fi

if [[ "${sync_states}" == true ]]; then
    print_step "Syncing states"

    # Create states folder if needed
    mkdir -p "${STATES_DST_BASE_DIR}"

    # Disable states
    print_sub_step "Disable states"

    qubesctl top.disable "${SALT_ROOT}"

    # Clean up states
    print_sub_step "Clean states"

    rm -fr "${STATES_DST_BASE_DIR}/${SALT_ROOT}"

    # Retrieve states
    print_sub_step "Retrieve states"

    STATES_SRC_DIR="${SRC_DIR}/${STATES_FOLDER}"
    STATES_ARCHIVE="${STATES_DST_BASE_DIR}/${SALT_ROOT}.tgz"

    qvm-run --pass-io ${QDOMAIN} "tar czf - -C ${STATES_SRC_DIR} ${SALT_ROOT}" > "${STATES_ARCHIVE}"
    tar xzf "${STATES_ARCHIVE}" -C "${STATES_DST_BASE_DIR}" && rm "${STATES_ARCHIVE}"

    # Enable states
    print_sub_step "Enable states"

    qubesctl top.enable "${SALT_ROOT}"

fi
