DOS Bridge  build 17  (2026-09-01)

dosbridge client kit
====================

Copy this whole folder onto the DOS machine, then from that folder:

    INSTALL              mTCP assumed in C:\MTCP
    INSTALL C:\MTCP   mTCP somewhere else

That creates C:\AI, C:\AGENT, C:\TOOLS and C:\WORK, installs the agent
loop and the tools, and writes C:\AUTOEXEC.NEW as a suggestion. It does
NOT modify AUTOEXEC.BAT or CONFIG.SYS.

NOT IN THIS KIT - you must supply these yourself:

  Packet driver     PM2000.COM (PicoMEM) or NE2000.COM
  mTCP              HTGET.EXE and NC.EXE are required.
                    DHCP.EXE is NOT - see below.
  CHOICE.COM        ships with DOS 6.22, used as a sleep
  DEVLOAD.COM       only needed for driver testing (dosdrv). Freeware.

Server (the Windows PC) : 192.168.50.46
This machine (static)   : 192.168.50.66

DO NOT RUN DHCP. It takes a lease, nothing renews it, and when the lease
expires every mTCP tool stops working and this machine goes silent. The
agent loop cannot recover from it -- it retries forever but never re-runs
DHCP -- so it costs somebody a walk to the keyboard.

After INSTALL, reboot. The Windows side should log a poll within seconds:

    dosctl status      ->  DOS box: alive, polled 0.4s ago
