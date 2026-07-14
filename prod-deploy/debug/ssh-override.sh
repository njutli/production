#!/bin/bash
# SSH override: direct WSL → 157 (bypass HK ECS fail2ban)

export SSH_USER="sunrise"
export SSH_PASSWORD="Sunrise@801"
export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
export CLIENT_EXT="203.156.3.194"
export CLIENT_PORT="19891"
export CLIENT_SERVER="10.20.1.157"
export SLAVE_SERVERS=("10.20.1.150" "10.20.1.151" "10.20.1.152")
export HK_ECS="190.92.233.189"
export HK_ECS_USER="root"
export HK_ECS_PASSWORD="Sunrise@801"

ssh_to_client() {
    local cmd="$1"
    local encoded
    encoded=$(echo -n "$cmd" | base64 -w0)
    sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} -p "${CLIENT_PORT}" "${SSH_USER}@${CLIENT_EXT}" "echo ${encoded} | base64 -d | bash"
}

ssh_to_slave() {
    local ip=$1 cmd="$2"
    local b64_slave b64_157 cmd_157
    b64_slave=$(echo -n "$cmd" | base64 -w0)
    cmd_157="sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T ${SSH_USER}@${ip} 'echo ${b64_slave} | base64 -d | bash'"
    b64_157=$(echo -n "$cmd_157" | base64 -w0)
    sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} -p "${CLIENT_PORT}" "${SSH_USER}@${CLIENT_EXT}" "echo ${b64_157} | base64 -d | bash"
}

_run() {
    local ip=$1; shift
    if [ "${ip}" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "$*"
    else
        ssh_to_slave "${ip}" "$*"
    fi
}

scp_to() {
    local src=$1 ip=$2 dest=$3
    local b64
    b64=$(base64 -w0 "$src")
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "echo '${b64}' | base64 -d > '${dest}'"
    else
        ssh_to_slave "$ip" "echo '${b64}' | base64 -d > '${dest}'"
    fi
}
