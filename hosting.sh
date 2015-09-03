################################################################################
# The MIT License (MIT)                                                        #
#                                                                              #
# Copyright (c) 2015 Matthew Bentley <matthew@bentley.link>                    #
#                                                                              #
# Permission is hereby granted, free of charge, to any person obtaining a copy #
# of this software and associated documentation files (the "Software"), to deal#
# in the Software without restriction, including without limitation the rights #
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell    #
# copies of the Software, and to permit persons to whom the Software is        #
# furnished to do so, subject to the following conditions:                     #
#                                                                              #
# The above copyright notice and this permission notice shall be included in   #
# all copies or substantial portions of the Software.                          #
#                                                                              #
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR   #
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,     #
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE  #
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER       #
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,#
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN    #
# THE SOFTWARE.                                                                #
################################################################################


#!/bin/bash

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

mkdir -p /var/run/netns

export name=$2
# If $name is already in the containers file, get info from there
# otherwise get it from the command line
if [[ -n $(cat ./containers.txt | grep -e "^${name} ") ]]; then
    export mac=$(cat ./containers.txt | grep -e "^${name} " | awk '{ print $2 }')
    export cname=$(cat ./containers.txt | grep -e "^${name} " | awk '{print $3 }')
    export mountloc=$(cat ./containers.txt | grep -e "^${name} " | awk '{print $4 }')
    export crun=$(cat ./containers.txt | grep -e "^${name} " | cut -d' ' -f5-)
    export fromfile=1
else
    #MAC address (ie 01:23:45:67:89:ab )
    export mac=$3
    export cname=$4
    export mountloc=$5
    #What to add after --name $name in the run command
    export crun=$@ | cut -d' ' -f5-
    export fromfile=0
fi

function if_create {
    #Create interface
    if [[ $mac = '0' ]]; then
        echo 'No interface'
    else
        ip link add ${name} link eth0 address ${mac} type macvlan mode bridge
    fi
}

function if_up {
#    if [[ $mac = '0' ]]; then
#        echo
#    else
#        #DHCP
#        dhclient ${name}
#
#        #up
#        ip link set ${name} up
#    fi
    if [[ $mac = '0' ]]; then
        echo
    else
        PID=`docker inspect -f '{{.State.Pid}}' ${name}`
        sudo ln -s /proc/${PID}/ns/net /var/run/netns/${PID}
        sudo ip l set ${name} netns ${PID}
        sudo ip netns exec ${PID} ip r del default
        sudo ip netns exec ${PID} dhcpcd ${name} & echo $! > ${name}_dhcp.pid
    fi
}

function if_down {
#    if [[ $mac = '0' ]]; then
#        echo
#    else
#        dhclient -d -r ${name}
#        ip link set dev ${name} down
#        ip link del dev ${name}
#_    fi
    if [[ $mac = '0' ]]; then
        echo
    else
        PID=`docker inspect -f '{{.State.Pid}}' ${name}`
        sudo ip netns exec ${PID} dhcpcd -k ${name}
    fi
}

function container_start {
    #Start docker :)
    docker kill ${name}
    docker rm ${name}
    docker pull ${cname} || echo "Could not pull. Continuing anyways"
    echo "docker run --name -v $(pwd)/${name}:${mountloc} ${name} -d ${crun}"
    docker run --name ${name} -v $(pwd)/${name}:${mountloc} -d ${crun}
}

function container_stop {
    docker stop ${name}
    docker rm ${name}
}

function get_internal_ip {
    #Internal ip
    export internal_ip=$(docker inspect --format='{{.NetworkSettings.IPAddress}}' ${name})
}

function get_external_ip {
    #External ip
    export external_ip=$(ifconfig | grep ${name} -A1 | grep 'inet addr:'| \
        grep -v '127.0.0.1' | cut -d: -f2 | awk '{ print $1}')
}

function iptables_create {
    if [[ $mac = '0' ]]; then
        echo
    else
        #Bridge name
        export bridge=BRIDGE-${name^^}

       #iptables FTFW
        iptables -t nat -N ${bridge}
        iptables -t nat -A PREROUTING -p all -d ${external_ip} -j ${bridge}
        iptables -t nat -A OUTPUT -p all -d ${external_ip} -j ${bridge}
        iptables -t nat -A ${bridge} -p all -j DNAT --to-destination ${internal_ip}
        iptables -t nat -I POSTROUTING -p all -s ${internal_ip} -j SNAT \
            --to-source ${external_ip}
    fi
}

function iptables_destroy {
    if [[ $mac = '0' ]]; then
        echo
    else
        #Bridge name
        export bridge=BRIDGE-${name^^}

        iptables -t nat -D POSTROUTING -p all -s ${internal_ip} -j SNAT \
            --to-source ${external_ip}
        iptables -t nat -D ${bridge} -p all -j DNAT --to-destination ${internal_ip}
        iptables -t nat -D OUTPUT -p all -d ${external_ip} -j ${bridge}
        iptables -t nat -D PREROUTING -p all -d ${external_ip} -j ${bridge}
    fi
}

function to_file {
    echo ${name} ${mac} ${cname} ${mountlog} ${crun} >> ./containers.txt
    mkdir ./${name}
}

function remove_from_file {
    sed -i "/^${name} /d" ./containers.txt
    rm -r ./${name}
}

function up {
    # Assumes interface already exists
    container_start
#    export internal_ip=$(docker inspect --format='{{.NetworkSettings.IPAddress}}' ${name})
#    export external_ip=$(ifconfig | grep ${name} -A1 | grep 'inet addr:'| \
#        grep -v '127.0.0.1' | cut -d: -f2 | awk '{ print $1}')
#    iptables_create
}

function down {
    # Leaves interface in place
    # TODO: check if it's actually running
    export external_ip=$(ifconfig | grep ${name} -A1 | grep 'inet addr:'| \
        grep -v '127.0.0.1' | cut -d: -f2 | awk '{ print $1}')
    export internal_ip=$(docker inspect --format='{{.NetworkSettings.IPAddress}}' ${name})
#    iptables_destroy
    container_stop
}

function start {
    if_create
    up
    if_up
}

function stop {
    if_down
    down
}

function create {
    # TODO: fail if already exists in containers.txt
    start
    to_file
}

function destroy {
    # CAUTION: this removes all info from containers.txt
    stop
    remove_from_file
}

function restart {
    stop
    start 
}


[[ $1 == 'create' ]] && create
[[ $1 == 'destroy' ]] && destroy
[[ $1 == 'up' ]] && up
[[ $1 == 'down' ]] && down
[[ $1 == 'start' ]] && start
[[ $1 == 'stop' ]] && stop
[[ $1 == 'restart' ]] && restart
