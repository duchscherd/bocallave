#!/bin/sh

# Delete these two lines after configuring.

echo "You need to edit this file with your information to use."
exit

# Define connection information.

secret="<secret>"
host="<host>"
port="<port>"

# If behind a NAT, you will need to use the external IP address.  The
# default is to look the IP from a site on the internet.

src_ip=$(curl -s zx2c4.com/ip | head -1)

# MacOS allows the storing credentials in a keychain so we can look up
# the data via the keychain label.  To create an keychain entry, use
# the command:
#
# security add-generic-password -l <label> -a <port> -s <host> -w <secret>

# To use MacOS keychain, uncomment the following lines.
# label=$1
# secret=$(security find-generic-password -l ${label} -w)
# host=$(security find-generic-password -l ${label} | awk -F\" '/svce/ { print $4 }')
# port=$(security find-generic-password -l ${label} | awk -F\" '/acct/ { print $4 }')

now=$(($(date +%s) / 5))
printf "${src_ip}${now}" | openssl dgst -hmac ${secret} -sha256 | tr -d '\n' | nc -w 0 -u ${host} ${port}
