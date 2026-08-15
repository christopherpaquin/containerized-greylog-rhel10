#!/usr/bin/env bats
# Firewalld logic (firewall-cmd is stubbed).

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
}

teardown() { common_teardown; }

@test "firewall_open_port calls firewall-cmd with --permanent --add-port" {
  stub firewall-cmd 0
  firewall_open_port "9000/tcp"
  calls_of firewall-cmd | grep -q -- "--permanent --add-port=9000/tcp"
}

@test "firewall_close_port calls firewall-cmd with --permanent --remove-port" {
  stub firewall-cmd 0
  firewall_close_port "9000/tcp"
  calls_of firewall-cmd | grep -q -- "--permanent --remove-port=9000/tcp"
}

@test "firewall_close_port does not fail if the port is already absent" {
  stub firewall-cmd 1
  run firewall_close_port "9000/tcp"
  [ "$status" -eq 0 ]
}

@test "firewall_reload calls firewall-cmd --reload" {
  stub firewall-cmd 0
  firewall_reload
  calls_of firewall-cmd | grep -q -- "--reload"
}

@test "deploy.sh only opens the three documented ports, nothing else" {
  # GRAYLOG_HTTP_PORT (web), SYSLOG_TCP_PORT, SYSLOG_UDP_PORT - and nothing
  # for MongoDB/Data Node, which must never be published to the host.
  grep -n 'ports=(' "${REPO_ROOT}/deploy.sh" | grep -q 'GRAYLOG_HTTP_PORT.*SYSLOG_TCP_PORT.*SYSLOG_UDP_PORT'
}

@test "MongoDB Quadlet unit never publishes a port" {
  ! grep -q '^PublishPort=' "${REPO_ROOT}/quadlet/mongodb.container"
}

@test "Data Node Quadlet unit never publishes a port" {
  ! grep -q '^PublishPort=' "${REPO_ROOT}/quadlet/graylog-datanode.container"
}

@test "deploy.sh assigns the Podman bridge interface to the firewalld trusted zone" {
  # Without this, inter-container DNS (aardvark-dns) silently breaks as
  # soon as anything triggers a firewalld reload - discovered live during
  # integration testing. External exposure is still controlled solely by
  # the explicit PublishPort mappings, not by this zone assignment.
  grep -q "zone=trusted --add-interface" "${REPO_ROOT}/deploy.sh"
}

@test "uninstall.sh removes the trusted-zone interface binding it added" {
  grep -q "zone=trusted --remove-interface" "${REPO_ROOT}/uninstall.sh"
}
