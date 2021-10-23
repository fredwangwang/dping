#!/bin/bash

set -eu

if [[ $# != 1 ]]; then
    echo "Usage: $0 <inventory-file>"
    exit 1
fi

function hasbinary() {
    if ! command -v "$1" &> /dev/null; then
        echo "$1 required"
        exit 1
    fi
}

hasbinary ansible
hasbinary python3

pingcount=100
pingpayload=500
pinginterval=0.5

filename="$(basename $1)"
envname="${filename%%.*}"
pingsummary="${envname}PingSummary"
pingsummarycsv="${pingsummary}.csv"
iplist="$(grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" "$1")"

cat > nodeping.sh <<EOL
#!/bin/bash

ips=\$(
    cat <<EOF
$iplist
EOF
)

pushd /tmp

i=0
for ip in \$ips; do
    ping -W 1 -c $pingcount -i $pinginterval -s $pingpayload \$ip > \$ip &
    pids[\$i]=\$!
    i=\$((i+1))
done

# wait for all
for pid in \${pids[*]}; do
    wait \$pid
done

echo -n > $pingsummary
for ip in \$ips; do
    tail -n3 \$ip >> $pingsummary
done

popd
EOL

cat > parsePingSummary.py <<EOF
with open('$pingsummary') as inf:
    alllines = inf.read()

from collections import defaultdict

lines = alllines.split('\n')
nodesping = defaultdict(dict)
currentnodeip = None
currenttargetip = None
for i in range(len(lines)):
    line = lines[i]
    # 10.0.0.131 | CHANGED | rc=0 >>
    if 'CHANGED' in line:
        # this is a node ip line
        parts = line.split(' ')
        currentnodeip = parts[0]
        continue
    # --- 10.0.0.127 ping statistics ---
    if 'ping statistics' in line:
        line = line[4:]
        parts = line.split(' ')
        currenttargetip = parts[0]
    # 200 packets transmitted, 192 received, 4% packet loss, time 920ms
    if 'packets transmitted' in line:
        parts = line.split(',')
        received = parts[1].strip()
        receivednum = received.split(' ')[0]
        nodesping[currentnodeip][currenttargetip]= receivednum

import csv

nodeips = list(nodesping.keys())
nodeips = sorted(nodeips)
fields = ['src\\\\dest'] + nodeips

with open ('$pingsummarycsv', 'w') as csvf:
    csvwriter = csv.writer(csvf)
    csvwriter.writerow(fields)
    for sip in nodeips:
        row = [sip]
        for dip in nodeips:
            row.append(nodesping[sip][dip])
        csvwriter.writerow(row)
EOF

export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_PYTHON_INTERPRETER=auto_silent

echo "open ICMP firewall and install/update iputils"
ansible -i $1 -f 30 -m shell -b -a 'iptables -A INPUT -p icmp -j ACCEPT && (tdnf install -y iputils || yum install -y iputils || apt-get update && apt-get install -y iputils-ping)' 'linux'

echo "run distributed ping, takes a few minutes..."
ansible -i $1 -f 30 -m script -b -a nodeping.sh 'linux'

echo "gather ping summary"
ansible -i $1 -f 30 -m shell -b -a "cat /tmp/$pingsummary" 'linux' > $pingsummary

echo "remove ICMP firewall rule"
ansible -i $1 -f 30 -m shell -b -a 'iptables -D INPUT -p icmp -j ACCEPT' 'linux'

python3 parsePingSummary.py
echo "finished: $pingsummarycsv"
