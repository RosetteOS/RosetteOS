# RosetteOS OOM priority policy (MEM-T07). Sourced by service init scripts.
#
# Each service gets its oom_score_adj at process birth: the value is written to
# a subshell's own /proc/self/oom_score_adj and start-stop-daemon is exec'd from
# it, so the daemon and every child inherit it. The previous pattern wrote
# /proc/$(cat pidfile)/oom_score_adj after start-stop-daemon -b returned, which
# raced the fork and, with a stale pidfile, could adjust an unrelated process.
#
# Printer-critical processes are protected, optional UI/camera/update work is
# expendable. klipper_mcu is tiny and must never be the victim (-1000); klippy
# stays killable as a last resort (-900) so the kernel always has a sensible
# victim.
ROSETTEOS_ADJ_KLIPPER_MCU=-1000
ROSETTEOS_ADJ_KLIPPY=-900
ROSETTEOS_ADJ_MEMGUARD=-900
ROSETTEOS_ADJ_MOONRAKER=-400
ROSETTEOS_ADJ_TOUCH_UI=0
ROSETTEOS_ADJ_GUPPYSCREEN=0
ROSETTEOS_ADJ_USTREAMER=300
ROSETTEOS_ADJ_UPDATE_SUPERVISOR=500
ROSETTEOS_ADJ_BOOTANIM=600

# rosetteos_start_with_adj <adj> <command...>: run command with oom_score_adj set
# before it starts.
rosetteos_start_with_adj() {
	_rosetteos_adj="$1"
	shift
	( echo "$_rosetteos_adj" > /proc/self/oom_score_adj 2>/dev/null; exec "$@" )
}
