#!/bin/sh
# udhcpc script - called by BusyBox udhcpc when it gets a DHCP lease

case "$1" in
    bound|renew)
        # Set IP address
        ip addr flush dev "$interface" 2>/dev/null
        ip addr add "$ip/${mask:-24}" dev "$interface" 2>/dev/null

        # Set default gateway
        if [ -n "$router" ]; then
            ip route del default 2>/dev/null
            for gw in $router; do
                ip route add default via "$gw" dev "$interface" 2>/dev/null
                break
            done
        fi

        # Set DNS
        if [ -n "$dns" ]; then
            echo -n > /etc/resolv.conf
            for ns in $dns; do
                echo "nameserver $ns" >> /etc/resolv.conf
            done
        fi

        # Set hostname
        [ -n "$hostname" ] && echo "$hostname" > /proc/sys/kernel/hostname
        ;;

    deconfig)
        ip addr flush dev "$interface" 2>/dev/null
        ip link set "$interface" up 2>/dev/null
        ;;
esac
