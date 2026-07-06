```
[S5720-28X-PWR-SI-AC]vlan batch 31 32 33 # create vlans
[S5720-28X-PWR-SI-AC]interface GigabitEthernet 0/0/1 # for each AP port
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/1]port link-type trunk
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/1]port trunk pvid vlan 1
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/1]port trunk allow-pass vlan 31
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/1]port trunk allow-pass vlan 32
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/1]port trunk allow-pass vlan 33
# for each AP port
```

pve port

```
[S5720-28X-PWR-SI-AC]interface GigabitEthernet 0/0/13
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/13]port link-type trunk
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/13]port trunk pvid vlan 1
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/13]port trunk allow-pass vlan 31
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/13]port trunk allow-pass vlan 32
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/13]port trunk allow-pass vlan 33
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/13]port trunk allow-pass vlan 40
```

vlanif

```
[S5720-28X-PWR-SI-AC]interface vlanif 31
[S5720-28X-PWR-SI-AC-Vlanif31]ip address 192.168.131.2 24
[S5720-28X-PWR-SI-AC-Vlanif31]quit
# for each vlan (31-33)
```

deny limit/iot -> mgmt

```
[S5720-28X-PWR-SI-AC]acl 3000
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny ip source 192.168.132.0 0.0.0.255 destination 192.168.130.0 0.0.0.255 # mgmt
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny ip source 192.168.133.0 0.0.0.255 destination 192.168.130.0 0.0.0.255 # mgmt

[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.132.0 0.0.0.255 destination 192.168.131.1 0.0.0.0 destination-port range 1 1000 # ikuai
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.132.0 0.0.0.255 destination 192.168.132.1 0.0.0.0 destination-port range 1 1000 # ikuai
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.132.0 0.0.0.255 destination 192.168.133.1 0.0.0.0 destination-port range 1 1000 # ikuai
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.133.0 0.0.0.255 destination 192.168.131.1 0.0.0.0 destination-port range 1 1000 # ikuai
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.133.0 0.0.0.255 destination 192.168.132.1 0.0.0.0 destination-port range 1 1000 # ikuai
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.133.0 0.0.0.255 destination 192.168.133.1 0.0.0.0 destination-port range 1 1000 # ikuai

[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.132.0 0.0.0.255 destination 192.168.131.2 0.0.0.0 destination-port range 1 1000 # s5720
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.132.0 0.0.0.255 destination 192.168.132.2 0.0.0.0 destination-port range 1 1000 # s5720
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.132.0 0.0.0.255 destination 192.168.133.2 0.0.0.0 destination-port range 1 1000 # s5720
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.133.0 0.0.0.255 destination 192.168.131.2 0.0.0.0 destination-port range 1 1000 # s5720
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.133.0 0.0.0.255 destination 192.168.132.2 0.0.0.0 destination-port range 1 1000 # s5720
[S5720-28X-PWR-SI-AC-acl-adv-3000]rule deny tcp source 192.168.133.0 0.0.0.255 destination 192.168.133.2 0.0.0.0 destination-port range 1 1000 # s5720

[S5720-28X-PWR-SI-AC-acl-adv-3000]quit

[S5720-28X-PWR-SI-AC]traffic classifier dstmgmt
[S5720-28X-PWR-SI-AC-classifier-dstmgmt]if-match acl 3000
[S5720-28X-PWR-SI-AC-classifier-dstmgmt]quit

[S5720-28X-PWR-SI-AC]traffic behavior denydstmgmt
[S5720-28X-PWR-SI-AC-behavior-denydstmgmt]deny
[S5720-28X-PWR-SI-AC-behavior-denydstmgmt]quit

[S5720-28X-PWR-SI-AC]traffic policy denydstmgmt
[S5720-28X-PWR-SI-AC-trafficpolicy-denydstmgmt]classifier dstmgmt behavior denydstmgmt
[S5720-28X-PWR-SI-AC-trafficpolicy-denydstmgmt]quit

[S5720-28X-PWR-SI-AC]interface GigabitEthernet 0/0/1
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/1]traffic-policy denydstmgmt inbound
[S5720-28X-PWR-SI-AC-GigabitEthernet0/0/1]quit
# for each AP port, and port using limit/iot vlan (32-33)
```

外网限速：爱快IP限速
内网限速：AP层面限速