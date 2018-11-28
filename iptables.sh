INTERFACE="eth0"

iptables -A INPUT -i $INTERFACE -p tcp --dport 80 -j ACCEPT

iptables -A INPUT -i $INTERFACE -p tcp --dport 3000 -j ACCEPT

iptables -A PREROUTING -t nat -i $INTERFACE -p tcp --dport 3000 -j REDIRECT --to-port 80
