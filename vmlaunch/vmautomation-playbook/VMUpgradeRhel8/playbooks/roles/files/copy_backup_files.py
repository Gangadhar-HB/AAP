#!/bin/python
#
# Copyright Motorola Solutions, Inc. and/or Kodiak Networks, Inc.                                 
# All Rights Reserved                                                                             
# Motorola Solutions Confidential Restricted                                                      
#

#!/bin/python

import os,logging,sys,subprocess
from subprocess import *


logger = logging.getLogger('copy_backup_files')
logger.setLevel(logging.DEBUG)
handler = logging.FileHandler('copybackupfiles.log')
handler.setLevel(logging.DEBUG)
formatter = logging.Formatter('%(asctime)s :%(name)s :%(levelname)s : %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)
ch = logging.StreamHandler()
ch.setLevel(logging.INFO)
#ch.setFormatter(formatter)
logger.addHandler(ch)

CPY = '/bin/cp'
CWD = os.getcwd()
DKR_PATH = '/etc/sysconfig'
SU_CMD= '/bin/sudo'
SED_CMD = '/usr/bin/sed'
DKR_NW = 'docker-network'
RM = '/bin/rm'
FS_PTH = '/etc'
USR_PTH = '/usr/local/etc'
LS_CMD = '/usr/bin/ls'

def cmdline(command):
    process = Popen(
        args=command,
        stdout=PIPE,
        shell=True
    )
    return process.communicate()[0]

def dkr_nw():

    logger.debug("Deleting file docker network file in current path if already exists")
    logger.debug(cmdline("%s -rf %s/sysconfig/%s"%(RM,USR_PTH,DKR_NW)))
    logger.debug("Copy and edit docker network file")
    logger.debug(cmdline("%s /bin/echo '# /etc/sysconfig/docker-network' > %s/sysconfig/%s"%(SU_CMD,USR_PTH,DKR_NW)))
    logger.debug(cmdline("%s /bin/echo '#DOCKER_NETWORK_OPTIONS=--bridge=none' >> %s/sysconfig/%s"%(SU_CMD,USR_PTH,DKR_NW)))
    logger.debug(cmdline("%s /bin/echo 'DOCKER_NETWORK_OPTIONS=--bip=172.17.42.1/24' >> %s/sysconfig/%s"%(SU_CMD,USR_PTH,DKR_NW)))
    logger.debug(cmdline("/bin/echo 'y'|%s %s  %s/sysconfig/%s %s/%s"%(SU_CMD,CPY,USR_PTH,DKR_NW,DKR_PATH,DKR_NW)))
    return "docker-network file is created"

def main():
    
    logger.info("\n ***** Copying necessary files from /etc to /usr *****\n")
    if not os.path.isdir("/usr/local/etc/sysconfig"):
        logger.debug(cmdline("%s /bin/mkdir /usr/local/etc/sysconfig "%SU_CMD))
    if os.path.isfile("/etc/sysconfig/clock"):
        logger.debug(cmdline("%s %s /etc/sysconfig/clock /usr/local/etc/sysconfig/"%(SU_CMD,CPY)))
    timezone=cmdline("sudo /bin/cat /usr/local/etc/sysconfig/clock | /bin/cut -d '=' -f2 | /bin/sed 's/\"//g'").rstrip()
    logger.debug("Create timezone file ")
    logger.debug(cmdline("%s /bin/echo '/usr/share/zoneinfo/%s' > /usr/local/etc/timezone"%(SU_CMD,timezone)))
    logger.debug("Copy fstab file from /etc")
    logger.debug(cmdline("%s %s -r %s/fstab %s"%(SU_CMD,CPY,FS_PTH,USR_PTH)))
    logger.debug("Copy sysctl files")
    in_file = open('%s/sysctlnew.conf'%CWD, 'rb')
    indata = in_file.read()
    logger.debug(cmdline("%s %s -r /etc/sysctl.conf %s/sysctl.conf"%(SU_CMD,CPY,USR_PTH)))
    logger.debug(cmdline("%s %s -r /etc/sysctl.conf %s/sysctlold.conf"%(SU_CMD,CPY,CWD)))
    out_file = open('%s/sysctl.conf'%USR_PTH, 'a')
    out_file.write(indata)
    f = open('%s/sysctl.conf'%USR_PTH,'r')
    lines = f.readlines()
    f.close()
    f = open('%s/sysctl.conf'%USR_PTH,'w')
    for line in lines:
    	if line!="kernel.core_pattern = /kdump/corefiles/core-%e.%s.%t.%h.%u"+"\n":
    		f.write(line)
    f.close()
    logger.debug("Copy iptables files from /etc to /usr")
    logger.debug(cmdline("%s %s -r %s/ip* %s/sysconfig/"%(SU_CMD,CPY,DKR_PATH,USR_PTH))) 
    logger.debug("Copy docker files from /etc to /usr")
    logger.debug(cmdline("%s %s -r %s/docker %s/sysconfig/"%(SU_CMD,CPY,DKR_PATH,USR_PTH)))
    logger.debug(dkr_nw())
    logger.debug(cmdline("%s %s -r %s/docker-registry %s/sysconfig/"%(SU_CMD,CPY,DKR_PATH,USR_PTH)))
    logger.debug(cmdline("%s %s -r %s/docker-storage %s/sysconfig/"%(SU_CMD,CPY,DKR_PATH,USR_PTH)))
    logger.debug(cmdline("%s %s -r %s/docker-storage-setup %s/sysconfig/"%(SU_CMD,CPY,DKR_PATH,USR_PTH)))
    logger.debug(cmdline("%s /bin/echo 'OK' > vm_config_state.txt"%SU_CMD))
    logger.debug(cmdline("%s %s vm_config_state.txt %s"%(SU_CMD,CPY,USR_PTH)))
    logger.info("List of files copied to backup location are:\n")
    logger.info(cmdline("%s %s -1 %s/sysconfig/docker*"%(SU_CMD,LS_CMD,USR_PTH)))
    logger.info(cmdline("%s %s -1 %s/fs*"%(SU_CMD,LS_CMD,USR_PTH)))
    logger.info(cmdline("%s %s -1 %s/vm_*"%(SU_CMD,LS_CMD,USR_PTH))) 
    logger.info("Installing tzdata package in all containers")
    container_list=cmdline("sudo docker ps -a | grep -v CREATED | awk '{print $NF}'").rstrip()
    logger.info("Currently runnning containers \n %s"%container_list)
    logger.info("copy rpms package to /DGdata/Software")
    logger.debug(cmdline("sudo %s -f %s/tzdata-* /DGdata/Software"%(CPY,CWD)))
    for container in container_list.rsplit('\n'):
    	logger.debug(cmdline("sudo docker exec -i %s /bin/rpm -Uvh /Software/tzdata-2018c-1.el7.noarch.rpm"%container))
    return "\n *** Required files are copied ***"

if __name__=='__main__':
    print main()

