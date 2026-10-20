# Pop!_OS maintenance

- `maint-check.sh`: Read-only report of pending updates and system health (intended display is custom bashrc-based banner/MOTD)
- `maint-apply.sh`: Interactive apply run with preflight, protected-removal
  gate, and a reboot gate that verifies the NVIDIA module for the next boot

Install: `./install.sh` (copies to /usr/local/sbin, root-owned)
Failure marker: `/var/lib/maint-apply/LAST_RUN_FAILED`
Logs: `/var/log/maint-apply/`
