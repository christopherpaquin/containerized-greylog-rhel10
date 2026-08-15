# Syslog forwarding examples

## Testing locally with `logger`

```bash
# TCP
logger -n <graylog-host> -P 1514 -T -t myhost "test message over TCP"

# UDP
logger -n <graylog-host> -P 1514 -d -t myhost "test message over UDP"
```

`-T` forces TCP; `-d` forces UDP (GNU `logger`'s default without either flag is UDP). Both inputs are created automatically by `deploy.sh` on first run - see the Graylog UI under System → Inputs, or `curl -u <token>:token http://<graylog-host>:9000/api/system/inputs`, to confirm.

## rsyslog: centralized syslog server forwarding to Graylog

If this Graylog instance is itself the destination for a separate centralized rsyslog server (collecting from many network devices/hosts), forward with `omfwd`, preferring **TCP** for reliability with a disk-assisted queue so messages survive a brief network blip:

```text
# /etc/rsyslog.d/90-forward-to-graylog.conf
action(
  type="omfwd"
  target="GRAYLOG_HOST"
  port="1514"
  protocol="tcp"
  action.resumeRetryCount="-1"
  queue.type="linkedList"
  queue.filename="graylog_fwd"
  queue.saveOnShutdown="on"
)
```

Restart rsyslog to apply: `sudo systemctl restart rsyslog`.

### Filtering by facility/severity before forwarding

```text
# Only forward auth and daemon facilities, warning and above
if ($syslogfacility-text == 'auth' or $syslogfacility-text == 'daemon') and $syslogseverity <= 4 then {
  action(type="omfwd" target="GRAYLOG_HOST" port="1514" protocol="tcp")
}
```

### UDP alternative (lower overhead, no delivery guarantee)

```text
action(type="omfwd" target="GRAYLOG_HOST" port="1514" protocol="udp")
```

Use UDP only for high-volume, loss-tolerant sources (e.g. verbose debug logging) - prefer TCP for anything you can't afford to lose, per this repo's design (TCP is the recommended path for server-to-Graylog forwarding).

## Network devices (Cisco/Juniper/etc.)

Point the device's syslog target at `<graylog-host>:1514` over UDP (most network OS syslog clients are UDP-only) or TCP if supported. Example (Cisco IOS):

```text
logging host <graylog-host> transport udp port 1514
```

## Windows (via a forwarder, not directly)

Graylog doesn't natively speak Windows Event Log; use an agent (e.g. NXLog, Winlogbeat with a syslog output) on the Windows host to forward as syslog to `<graylog-host>:1514`.
