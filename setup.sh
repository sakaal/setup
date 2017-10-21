#!/bin/sh
#
# Simple server setup script for testing purposes only.
# INSECURE - DO NOT USE ANYTHING LIKE THIS IN PRODUCTION.
#
# Copy this script (a single file) to /root/setup.sh and run it
# after installing a Fedora server with root account only.
# It installs Ansible, Git, and administrator local user accounts.
#
dnf install -y ansible git
cd /root
git init .
git remote add -t \* -f origin https://github.com/sakaal/setup.git
git fetch --all
git reset --hard origin/master
chmod og-wx setup.sh
ansible-playbook -v setup.yml
rm -f setup.retry
