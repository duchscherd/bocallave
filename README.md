# What is bocallave?

bocallave is a very simple client and server that is used to run a
command on a remote server triggered by the client sending a token to
a predefined UDP port on the server.

## What is it use it for?

My primary use for bocallave is to open the firewall port on a remote
server to allow laptop to access my VMs. It is generic enough that it
could be used to issue any command on the server.

## Design Goals

* Server does not respond in any way.
* Easy to generate secure token.
* Does not lesson the security of the server.
* Be simple to use and understand.

## Why lua?

* Small footprint
* Simple language
* I am learning lua language and wrting code help me learn the ins and outs of a lanugage.

## Prerequisites

* lua 5.x
* luaposix
* luaossl
* luacjson

## Token Format

There is a need to make sure it is hard on an attacker to forge their
own token and send it to the server. Taking some hints from HTOP and
TOTP specifications, the token is HMAC SHA256 hash of the source IP
address of the client and an interger representing the epoch time
divided by 5 (5 second windows) when the token as created.

    token = HMAC_SHA256(key, "192.168.0.1231591982439")

This will produce a token that looks like this:

    3ad0d8567bbd6fb508aec69430e0efde6eab65b4d08357bebde405a2f797bb14

## Token Verification

The server takes the source IP address from the received packet, the
current epoch time divided by 5, and recreates the token to compare to
the token that was received.  Since clocks may be out of sync, this is done for
the previous 5 second window and the next 5 second window.

## Configuration File

Configuration is via a configuration file that uses the JSON format.
It is an array of objects with the following fields:

* name - generic name for this entry.
* command - command with arguments that should be run when this port is triggered. *bocallaved only*
* address - network address to listen for requests on.  Use 0.0.0.0 for all addresses.
* port - network port to listen for requests on.
* secret - secret or key to used to secure the token.

**Example:**

```json
[
  {
    "name": "ssh",
    "command": "sudo ipset add ssh ${src_ip}",
    "address": "0.0.0.0",
    "port": 12345,
    "secret": "123456789012345678901234567890123456789012345678901234567890"
  }
]
```

## Environment

When the command is run, the following environmental variables are available.

* src_ip - source IP of received packet
* src_port - source port of received packet
* dst_ip - configuration entry address value.
* dst_port - configuration entry port value.
* config_name - configuration entry name value.

## Installation

You will need to install the prerequisites listed above.

* Copy bocallaved.lua to /usr/sbin/bocallaved
* Set bocallaved owner to root
* Set bocallaved group to root or wheel
* Set bocallaved permissions to 0500
* Create a group named bocallave
* Create a user named bocallave with the group set to bocallave, the
  shell set to /sbin/nologin, and password is locked.
* Create bocallaved configuration file: /etc/bocallaved.conf
* Set the permissions on /etc/bocallaved.conf to 0640
* Set the owner of /etc/bocallaved.conf to root
* Set the group of /etc/bocallaved.conf to bocallave

The default behavior for bocallaved is to run in the background as a
daemon and switches to the user/group of bocallave.

## Clients

There is currnetly only a single client, `bocallave.sh`, which is a
shell script. I will add additional clients as needed.

*Prerequisites*

* openssl
* tr
* nc

*Installation*

Just copy the script to your system and edit it to your
needs. Currently, it has very limited functionallity.

*Usage*

To use the bocallave.sh, just run it to send token to the server.

    bocallave.sh

## Example of setting up server to open a firewall port.

This example shows opening ssh port to the sender IP address for 5
minutes giving the sender enough time to start a SSH session. After 5
minutes, ipset will removed the sender's IP address.  You will need
iptables, ipset, and sudo installed and configured.

Setup an ipset for ssh:

    ipset create ssh hash:ip timeout 300

Add rules to iptables:

    iptables -A INPUT -i eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A INPUT -i eth0 -m set --match-set ssh src -p tcp -m tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

Configure bocallave (/etc/bocallave.conf):

```json
[
  {
    "name": "ssh",
    "command": "/usr/bin/sudo /usr/sbin/ipset add ssh ${src_ip} -exist",
    "address": "0.0.0.0",
    "port": 12345,
    "secret": "123456789012345678901234567890123456789012345678901234567890"
  }
]
```

Remember to use full path for all commands. bocallaved clears all
environmental variables including PATH.

Allow bocallave user to run command (/etc/sudoers.d/bocallave):

    bocallave ALL = (root) NOPASSWD: /usr/sbin/ipset add ssh *

Start up bocallave:

    /usr/sbin/bocallaved /etc/bocallaved.conf
