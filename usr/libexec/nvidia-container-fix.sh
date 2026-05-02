#! /bin/env bash

# Reclassify /dev/nvidia* devices with container SELinux type
semanage fcontext -a -t container_file_t '/dev/nvidia(.*)?'
restorecon -rv /dev/nvidia*

exit 0
