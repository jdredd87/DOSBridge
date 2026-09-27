DOS Bridge  build 66  (2026-09-26)

dosbridge client kit
====================

Copy this whole folder onto the DOS machine, then from that folder:

    INSTALL              mTCP, if you have it, in C:\MTCP
    INSTALL C:\MTCP   mTCP somewhere else

mTCP is optional. The bridge speaks UDP to the packet driver itself, so
that argument only decides where an otherwise unused MTCP.NEW is written.

That creates C:\AI, C:\AGENT, C:\TOOLS and C:\WORK, installs the agent
loop and the tools, and writes C:\AUTOEXEC.NEW as a suggestion. It does
NOT modify AUTOEXEC.BAT or CONFIG.SYS.

NOT IN THIS KIT - you must supply these yourself:

  Packet driver     PM2000.COM (PicoMEM) or NE2000.COM. REQUIRED -- it is
                    the one thing the bridge cannot provide for itself.
  CHOICE.COM        ships with DOS 6.22, used as a sleep
  DEVLOAD.COM       only needed for driver testing (dosdrv). Freeware.

mTCP is NO LONGER REQUIRED. The agent talks to the server over its own
IPv4/UDP stack (UGET.EXE and UPUT.EXE, TFTP on UDP 8069), reading its
addresses from C:\AI\NET.CFG in this kit. If you happen to have mTCP
installed its tools are still handy for diagnosis -- PING, SPDTEST, DNSTEST
-- and NET.CFG uses the same key names, so an existing MTCP.CFG can be
copied straight over it. But nothing here needs it to run.

Server (the Windows PC) : 192.168.1.10
This machine (static)   : 192.168.1.20

DO NOT RUN DHCP. It takes a lease, nothing renews it, and when the lease
expires every mTCP tool stops working and this machine goes silent. The
agent loop cannot recover from it -- it retries forever but never re-runs
DHCP -- so it costs somebody a walk to the keyboard.

After INSTALL, reboot. The Windows side should log a poll within seconds:

    dosctl status      ->  DOS box: alive, polled 0.4s ago
